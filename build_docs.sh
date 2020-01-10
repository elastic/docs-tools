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

export JRUBY_OPTS="-J-Xmx6g"
export GRADLE_OPTS="-Xmx6g -Dorg.gradle.daemon=false"

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

git config user.email "jenkins@elastic.co"
git config user.name "Logstash CI"

git add .

git status

git commit -m "updated docs for ${branch_specifier}" -a

git push origin $BRANCH

set +x
curl -H "Authorization: token $GITHUB_TOKEN" -X POST \
  -d "{\"title\": \"updated docs for ${branch_specifier}\",\"head\": \"${BRANCH}\",\"base\": \"${branch_specifier}\"}" \
  https://api.github.com/repos/elastic/logstash-docs/pulls
