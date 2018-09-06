#!/bin/bash
set -ex

if [ -z "$branch_specifier" ]; then
    echo "Environment variable 'branch_specifier' is required."
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
    echo "Environment variable 'GITHUB_TOKEN' is required."
    exit 1
fi

export JRUBY_OPTS="-J-Xmx2g"
export GRADLE_OPTS="-Xmx2g -Dorg.gradle.daemon=false"

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

perl ../docs/build_docs.pl --doc docs/index.asciidoc --chunk 1

cd ../logstash-docs

T="$(date +%s)"
BRANCH="update_docs_${T}"

git checkout -b $BRANCH

git add .

git commit --author="Logstash CI <jenkins@elastic.co>" -m "updated docs for ${branch_specifier}"

git push origin $BRANCH

curl -v -H "Authorization: token $GITHUB_TOKEN" -X POST -k \
  -d "{\"title\": \"updated docs for ${branch_specifier}\",\"head\": \"${BRANCH}\",\"base\": \"${branch_specifier}\"}" \
  https://api.github.com/repos/elastic/logstash-docs/pulls
