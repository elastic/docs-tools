#!/bin/bash
set -e

set +x

if [ -z "$branch_specifier" ]; then
    echo "Environment variable 'branch_specifier' is required."
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Environment variable 'GITHUB_TOKEN' is required."
    exit 1
fi

set -x

export PATH="$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"
rbenv local jruby-9.1.12.0

# cwd is "docs-tools" so lets go one step back
cd ..

echo "Cloning 'logstash-docs'"
git clone --depth 1 git@github.com:elastic/logstash-docs.git -b $branch_specifier

echo "Cloning 'logstash'"
git clone --depth 1 git@github.com:elastic/logstash.git -b $branch_specifier

echo "Cloning 'docs'"
git clone --depth 1 git@github.com:elastic/docs.git

cd logstash

# we did not back-port https://github.com/elastic/logstash/pull/12763 to 6.8
jvm_args="-Xmx4g" && [[ "$branch_specifier" == "6.8" ]] && jvm_args="-Xmx12g"

export GRADLE_OPTS="-Dorg.gradle.jvmargs=\"$jvm_args\""

if [ -n "$BUILD_JAVA_HOME" ]; then
  GRADLE_OPTS="$GRADLE_OPTS -Dorg.gradle.java.home=$BUILD_JAVA_HOME"
fi

./gradlew generatePluginsVersion

cd ../docs-tools

bundle install --path=vendor/bundle
bundle exec ruby plugindocs.rb --output-path ../logstash-docs ../logstash/plugins_version_docs.json

cd ../logstash

../docs/build_docs --asciidoctor --respect_edit_url_overrides --doc docs/index.asciidoc --resource=../logstash-docs/docs/ --chunk 1

cd ../logstash-docs

T="$(date +%s)"
BRANCH="update_docs_${T}"

git checkout -b $BRANCH

# This email address is associated with the `logstashmachine` user's record in
# the CLA Checker.
git config user.email "43502315+logstashmachine@users.noreply.github.com"
git config user.name "Logstash CI"

git add .

git status

git commit -m "updated docs for ${branch_specifier}" -a

git push origin $BRANCH

set +x
curl -H "Authorization: token $GITHUB_TOKEN" -X POST \
  -d "{\"title\": \"updated docs for ${branch_specifier}\",\"head\": \"${BRANCH}\",\"base\": \"${branch_specifier}\"}" \
  https://api.github.com/repos/elastic/logstash-docs/pulls
