#!/bin/bash
set -x

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

echo "Cloning 'logstash-docs'"
git clone --depth 1 git@github.com:elastic/logstash-docs.git -b $branch_specifier

echo "Cloning 'logstash'"
git clone --depth 1 git@github.com:elastic/logstash.git -b $branch_specifier

echo "Cloning 'docs'"
git clone --depth 1 git@github.com:elastic/docs.git

cd logstash

patch --strip=1 <../docs-tools/logstash/remove-setup-and-bootstrap-from-docs-rakelib.patch

rake test:install-core

echo "Generate json with plugins version"
# Since we generate the lock file and we try to resolve dependencies we will need
# to use the bundle wrapper to correctly find the rake cli. If we don't do this we
# will get an activation error,
./vendor/jruby/bin/rake generate_plugins_version

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

git commit -m "updated docs for ${branch_specifier}"

git push origin $BRANCH

curl -v -H "Authorization: token $GITHUB_TOKEN" -X POST -k \
  -d "{\"title\": \"updated docs for ${branch_specifier}\",\"head\": \"${BRANCH}\",\"base\": \"${branch_specifier}\"}" \
  https://api.github.com/repos/elastic/logstash-docs/pulls
