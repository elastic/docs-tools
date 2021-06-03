### Generate documentation of all versions of all plugins

The versioned_plugins.rb ruby script crawls the github repositories of the "logstash-plugins" organization
and generate the following structure:

```
docs/versioned-plugins
├── codecs
│   ├── cef-index.asciidoc
│   ├── cef-v5.0.1.asciidoc
│   ├── cef-v5.0.2.asciidoc
│   ├── rubydebug-index.asciidoc
│   ├── rubydebug-v3.0.3.asciidoc
│   ├── rubydebug-v3.0.4.asciidoc
│   ├── rubydebug-v3.0.5.asciidoc
├── codecs-index.asciidoc
├── filters
│   ├── mutate-index.asciidoc
│   ├── mutate-v3.1.5.asciidoc
│   ├── mutate-v3.1.6.asciidoc
│   ├── mutate-v3.1.7.asciidoc
│   ├── mutate-v3.2.0.asciidoc
│   ├── ruby-index.asciidoc
│   ├── ruby-v3.0.3.asciidoc
│   ├── ruby-v3.1.3.asciidoc
├── filters-index.asciidoc
├── ...
```
#### Requirements

* Ruby MRI
* Bundler
* GitHub Personal Access Token with "public_repo" scope: https://github.com/settings/tokens/new
* A clone of the logstash-docs repo: https://github.com/elastic/logstash-docs/

#### How to use

Instal dependencies with `bundle install`

```
% bundle exec ruby versioned_plugins.rb -h
Usage:
    versioned_plugins.rb [OPTIONS]

Options:
    --output-path OUTPUT          Path to the top-level of the logstash-docs path to write the output.
    --skip-existing               Don't generate documentation if asciidoc file exists
    --latest-only                 Only generate documentation for latest version of each plugin (default: false)
    --repair                      Apply several heuristics to correct broken documentation (default: false)
    --plugin-regex REGEX          Only generate if plugin matches given regex (default: "logstash-(?:codec|filter|input|output)")
    -h, --help                    print help

```

#### Example usages

* generate docs for new versions of plugins (doesn't overwrite existing files)

```
GITHUB_TOKEN=XXXXXXXXXXXXXX bundle exec ruby versioned_plugins.rb --output-path=/tmp/elastic/logstash-docs --skip-existing
```

* generate docs for all versions of a specific plugin and attempt to correct asciidoc errors

```
GITHUB_TOKEN=XXXXXXXXXXXXXX bundle exec ruby versioned_plugins.rb --output-path=/tmp/elastic/logstash-docs --plugin-regex "logstash-input-tcp" --repair
```
