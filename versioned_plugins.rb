require "clamp"
require "json"
require "fileutils"
require "time"
require "stud/try"
require "octokit"
require "erb"
require "pmap"

require_relative 'lib/core_ext/erb_result_with_hash'
require_relative 'lib/logstash-docket'
require_relative 'git_helper'

class VersionedPluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to a directory where logstash-docs repository will be cloned and written to", required: true
  option "--skip-existing", :flag, "Don't generate documentation if asciidoc file exists"
  option "--latest-only", :flag, "Only generate documentation for latest version of each plugin", :default => false
  option "--repair", :flag, "Apply several heuristics to correct broken documentation", :default => false
  option "--plugin-regex", "REGEX", "Only generate if plugin matches given regex", :default => "logstash-(?:codec|filter|input|output|integration)"
  option "--dry-run", :flag, "Don't create a commit or pull request against logstash-docs", :default => false
  option("--since", "STRING", "gems newer than this date", default: nil) { |v| v && Time.parse(v) }
  option("--parallelism", "NUMBER", "for performance", default: 4) { |v| Integer(v) }

  PLUGIN_SKIP_LIST = [
    "logstash-codec-example",
    "logstash-input-example",
    "logstash-filter-example",
    "logstash-output-example",
    "logstash-filter-script",
    "logstash-input-java_input_example",
    "logstash-filter-java_filter_example",
    "logstash-output-java_output_example",
    "logstash-codec-java_codec_example"
  ]

  # If plugins are under the logstash-plugins org, they will automatically explored.
  # However, if plugin is located in other org, we need to manually list up here in a {org}/{plugin-repo-name} format.
  ADDITIONAL_ORG_PLUGINS = [
    "elastic/logstash-filter-elastic_integration"
  ]

  STACK_VERSIONS_BASE_URL = "https://raw.githubusercontent.com/elastic/docs/master/shared/versions/stack/"

  def logstash_docs_path
    File.join(output_path, "logstash-docs")
  end

  def docs_path
    File.join(output_path, "docs")
  end

  attr_reader :octo, :stack_version, :ecs_version

  include LogstashDocket

  def execute
    setup_github_client
    check_rate_limit!
    clone_docs_repo
    fetch_stack_versions
    generate_docs
    if new_versions?
      unless dry_run?
        puts "creating pull request.."
        submit_pr
      end
    else
      puts "No new versions detected. Exiting.."
    end
  end

  def setup_github_client
    Octokit.auto_paginate = true
    if ENV.fetch("GITHUB_TOKEN", "").size > 0
      puts "using a github token"
    else
      puts "not using a github token"
    end
    @octo = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
  end

  def check_rate_limit!
    rate_limit = octo.rate_limit
    puts "Current GitHub rate limit: #{rate_limit.remaining}/#{rate_limit.limit}"
    if rate_limit.remaining < 100
      puts "Warning! Api rate limit is close to being reached, this script may fail to execute"
    end
  end

  def generate_docs
    puts "writing to #{logstash_docs_path}"
    repos = octo.org_repos("logstash-plugins")
    repos = repos.map {|repo| repo.name }.select {|repo| repo.match(plugin_regex) }
    repos = (repos - PLUGIN_SKIP_LIST).sort.uniq.map {|repo| "logstash-plugins/#{repo}"}
    repos = repos.concat(ADDITIONAL_ORG_PLUGINS)

    puts "found #{repos.size} repos"

    # TODO: make less convoluted
    timestamp_reference = since || Time.strptime($TIMESTAMP_REFERENCE, "%a, %d %b %Y %H:%M:%S %Z")
    puts "Generating docs since #{timestamp_reference.inspect}"

    plugins_indexes_to_rebuild = Util::ThreadsafeWrapper.for(Set.new)
    package_indexes_to_rebuild = Util::ThreadsafeWrapper.for(Set.new)

    plugin_version_index = Util::ThreadsafeIndex.new { Util::ThreadsafeWrapper.for(Set.new) }
    plugin_names_by_type = Util::ThreadsafeIndex.new { Util::ThreadsafeWrapper.for(Set.new) }

    # We need to fetch version metadata from repositories that contain plugins
    repos_requiring_rebuild = Util::ThreadsafeWrapper.for(Set.new)

    # we work from a single set of Repository objects
    repositories = repos.map do |repo_name|
      $stderr.puts("[#{repo_name}]: loading releases...")
      source = Source::Github.new(repo: repo_name, octokit: @octo)
      Repository::from_source(source.repo, source)
    end

    # Iterate over the repos to identify which need reindexing.
    # This is a bit complicated because a single repo is not the complete
    # source-of-truth for a plugin (e.g., previously stand-alone plugins
    # being absorbed into an integration plugin package)
    repositories.peach(parallelism) do |repository|
      latest_release = repository.last_release
      if latest_release.nil?
        $stderr.puts("#{repository.desc}: no releases on rubygems.\n")
        next
      end

      # if the repository has no releases, or none since our `timestamp_reference`,
      # it doesn't need to be added to the reindex list here.
      if latest_release.release_date.nil? || latest_release.release_date < timestamp_reference
        $stderr.puts("#{repository.desc}: no new releases.\n")
        next
      end

      # the repository has one or more releases since our `timestamp_reference`, which means
      # it will need to be reindexed.
      $stderr.puts("#{repository.desc}: found new release\n")
      # repos_requiring_rebuild.add(repository.name) &&
          # $stderr.puts("[repo:#{repository.name}]: marked for reindex\n")

      # if the latest release is an integration plugin, each of the plugins it contains
      # may have previously been sourced in a different repository; add the plugin name
      # to the list of repositories requiring reindexing.
      latest_release.with_embedded_plugins.each do |plugin|
        repos_requiring_rebuild.add(plugin.canonical_name) &&
            $stderr.puts("#{plugin.desc}: marking for reindex\n")
      end

    end

    # Now that we know which repositories require reindexing, we can start the work.
    repositories.peach(parallelism) do |repository|
      unless repos_requiring_rebuild.include?(repository.name)
        $stderr.puts("[repo:#{repository.name}]: rebuild not required. skipping.\n")
        latest_release = repository.last_release
        latest_release && latest_release.with_embedded_plugins.each do |plugin|
          next unless versions_index_exists?(plugin.name, plugin.type)
          plugin_names_by_type.fetch(plugin.type).add(plugin.name)
        end
        next
      end

      $stderr.puts("[repo:#{repository.name}]: rebuilding versioned docs\n")
      repository.source_tagged_releases.each do |released_plugin|
        released_plugin.with_embedded_plugins.each do |plugin|
          if expand_plugin_doc(plugin)
            plugins_indexes_to_rebuild.add(plugin.canonical_name)
            plugin_version_index.fetch(plugin.canonical_name).add(plugin)
            plugin_names_by_type.fetch(plugin.type).add(plugin.name)
          else
            $stderr.puts("#{plugin.desc}: documentation not available; skipping remaining releases from repository\n")
            break false
          end
        end || break

        break if latest_only?
      end
    end

    $stderr.puts("REINDEXING PLUGINS, loading plugin aliases...")
    alias_definitions_by_type = Util::AliasDefinitionsLoader.get_alias_definitions

    # add aliases named to the partitioned plugin names collection
    alias_definitions_by_type.each do |type, alias_definitions|
      alias_definitions.each do |alias_definition|
        plugin_names_by_type.fetch(type).add(alias_definition.fetch("alias"))
      end
    end

    # rewrite alias indices if target plugin was changed
    $stderr.puts("REINDEXING PLUGINS ALIASES... #{alias_definitions_by_type.size}\n")
    alias_definitions_by_type.each do |type, alias_definitions|
      alias_definitions.each do |alias_definition|
        $stderr.puts("[plugin:#{alias_definition.fetch("alias")}] reindexing\n")
        write_alias_index(type, alias_definition.fetch("alias"), alias_definition.fetch("from"))
      end
    end

    # rewrite incomplete plugin indices
    $stderr.puts("REINDEXING PLUGINS... #{plugins_indexes_to_rebuild.size}\n")
    plugins_indexes_to_rebuild.each do |canonical_name|
      $stderr.puts("[plugin:#{canonical_name}] reindexing\n")
      versions = plugin_version_index.fetch(canonical_name).sort_by(&:version).reverse.map do |plugin|
        [plugin.tag, plugin.release_date.strftime("%Y-%m-%d")]
      end
      _, type, name = canonical_name.split('-',3)
      write_versions_index(name, type, versions)
    end

    # rewrite integration package indices
    package_indexes_to_rebuild.each do |canonical_name|
      # TODO: build package indices
    end

    # rewrite versions-by-type indices
    $stderr.puts("REINDEXING TYPES... #{}\n")
    plugin_names_by_type.each do |type, names|
      $stderr.puts("[type:#{type}] reindexing\n")
      write_type_index(type, names.sort)
    end
  end

  def clone_docs_repo
    `git clone git@github.com:elastic/logstash-docs.git #{logstash_docs_path}`
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout versioned_plugin_docs`
      last_commit_date = `git log -1 --date=short --pretty=format:%cd`
      $TIMESTAMP_REFERENCE=(Time.parse(last_commit_date) - 24*3600).strftime("%a, %d %b %Y %H:%M:%S %Z")
    end
  end

  def new_versions?
    Dir.chdir(logstash_docs_path) do |path|
      `git diff --name-status`
      `! git diff-index --quiet HEAD`
      $?.success?
    end
  end

  def submit_pr
    branch_name = "versioned_docs_new_content"
    git_helper = GitHelper.new("elastic/logstash-docs")
    if git_helper.branch_exists?(branch_name)
      puts "WARNING: Branch \"#{branch_name}\" already exists. Not creating a new PR. Please merge the existing PR or delete the PR and the branch."
      return
    end

    pr_title = "auto generated update of versioned plugin documentation"
    git_helper.commit(logstash_docs_path, branch_name, "updated versioned plugin docs")
    git_helper.create_pull_request(branch_name, "versioned_plugin_docs", pr_title, "")
  end

  def branch_exists?(client, branch_name)
    client.branch("elastic/logstash-docs", branch_name)
    true
  rescue Octokit::NotFound
    false
  end

  ##
  # Expands and persists docs for the given `VersionedPlugin`, refusing to overwrite if `--skip-existing`.
  # Writes description of plugin with release date to STDOUT on success (e.g., "logstash-filter-mutate@v1.2.3 2017-02-28\n")
  #
  # @param plugin [VersionedPlugin]
  # @return [Boolean]: returns `true` IFF docs exist on disc.
  def expand_plugin_doc(plugin)
    release_tag = plugin.tag
    release_date = plugin.release_date ? plugin.release_date.strftime("%Y-%m-%d") : "unreleased"
    changelog_url = plugin.changelog_url

    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{plugin.type}s/#{plugin.name}-#{release_tag}.asciidoc"
    if File.exist?(output_asciidoc) && skip_existing?
      $stderr.puts "[#{plugin.desc}]: skipping - file already exists\n"
      return true
    end

    $stderr.puts "#{plugin.desc}: fetching documentation\n"
    content = plugin.documentation

    if content.nil?
      $stderr.puts("#{plugin.desc}: doc not found\n")
      return false
    end

    content = extract_doc(content, plugin.canonical_name, release_tag, release_date, changelog_url)

    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    File.write(output_asciidoc, content)
    puts "#{plugin.desc}: #{release_date}"
    true
  end

  def expand_package_doc(package)
    # TODO: expand package-specific doc
  end

  def extract_doc(doc, plugin_full_name, release_tag, release_date, changelog_url)
    _, type, name = plugin_full_name.split("-",3)
    # documenting what variables are used below this point
    # version: string, v-prefixed
    # date: string release date as YYYY-MM-DD
    # type: string e.g., from /\Alogstash-(?<type>input|output|codec|filter)-(?<name>.*)\z/
    # name: string e.g., from /\Alogstash-(?<type>input|output|codec|filter)-(?<name>.*)\z/
    # changelog_url: dynamically created from repository and version

    # Replace %VERSION%, etc
    content = doc \
      .gsub("%VERSION%", release_tag) \
      .gsub("%RELEASE_DATE%", release_date) \
      .gsub("%CHANGELOG_URL%", changelog_url) \
      .gsub(":include_path: ../../../../logstash/docs/include", ":include_path: ../include/6.x") \

    content = content.sub(/^=== .+? [Pp]lugin$/) do |header|
      "#{header} {version}"
    end

    if repair?
      content = content.gsub(/^====== /, "===== ")
        .gsub(/^\[source\]$/, "[source,shell]")
        .gsub('[id="plugins-{type}-{plugin}', '[id="plugins-{type}s-{plugin}')
        .gsub(":include_path: ../../../logstash/docs/include", ":include_path: ../include/6.x")
        .gsub(/[\t\r ]+$/,"")

      content = fix_configuration_file_structure_links(content)
        .gsub("<<event-api,Event API>>", "{logstash-ref}/event-api.html[Event API]")
        .gsub("<<dead-letter-queues>>", '{logstash-ref}/dead-letter-queues.html[dead-letter-queues]')
        .gsub("<<logstash-config-field-references>>", "{logstash-ref}/event-dependent-configuration.html#logstash-config-field-references[Field References]")
    end

    content = content.gsub('[id="plugins-', '[id="{version}-plugins-')
      .gsub("<<plugins-{type}s-common-options>>", "<<{version}-plugins-{type}s-{plugin}-common-options>>")
      .gsub("<<plugins-{type}-{plugin}", "<<plugins-{type}s-{plugin}")
      .gsub("<<plugins-{type}s-{plugin}", "<<{version}-plugins-{type}s-{plugin}")
      .gsub("<<plugins-#{type}s-#{name}", "<<{version}-plugins-#{type}s-#{name}")
      .gsub("[[dlq-policy]]", '[id="{version}-dlq-policy"]')
      .gsub("<<dlq-policy>>", '<<{version}-dlq-policy>>')
      .gsub("[Kafka Input Plugin @9.1.0](https://github.com/logstash-plugins/logstash-input-rabbitmq/blob/v9.1.0/CHANGELOG.md)", "[Kafka Input Plugin @9.1.0](https://github.com/logstash-plugins/logstash-input-kafka/blob/v9.1.0/CHANGELOG.md)")
      .gsub("[Kafka Output Plugin @8.1.0](https://github.com/logstash-plugins/logstash-output-rabbitmq/blob/v8.1.0/CHANGELOG.md)", "[Kafka Output Plugin @8.1.0](https://github.com/logstash-plugins/logstash-output-kafka/blob/v8.1.0/CHANGELOG.md)")

    if repair?
      content.gsub!(/<<plugins-.+?>>/) do |link|
        match = link.match(/<<plugins-(?<link_type>\w+)-(?<link_name>\w+)(?:,(?<link_text>.+?))?>>/)
        if match.nil?
          link
        else
          if match[:link_type] == "#{type}s" && match[:link_name] == name
            # do nothing. it's an internal link
            link
          else
            # it's an external link. let's convert it
            if match[:link_text].nil?
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_name]} #{match[:link_type][0...-1]} plugin]"
            else
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_text]}]"
            end
          end
        end
      end

      match = content.match(/\[id="{version}-plugins-{type}s-{plugin}-common-options"\]/)
      if match.nil? && type != "codec"
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]",
                     "[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]")
      end

      if type == "codec"
        content = content.sub("This plugin supports the following configuration options plus the <<{version}-plugins-{type}s-{plugin}-common-options>> described later.\n", "")
        content = content.sub("Also see <<{version}-plugins-{type}s-{plugin}-common-options>> for a list of options supported by all\ncodec plugins.\n", "")
        content = content.sub("\n[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]", "")
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]", "")
      end
    end

    write_stack_versions(content, type)
  end
  
  # transforms '<<ANCHOR,ANYTHING>>' into {logstash-ref}/configuration-file-structure.html#ANCHOR[ANYTHING]
  def fix_configuration_file_structure_links(content)
    anchors = %w(
      string
      array
      number
      boolean
      hash
      password
      path
      uri
      bytes
    )
    content.gsub(/<<(#{Regexp.union(anchors)}),(.+?)>>/, '{logstash-ref}/configuration-file-structure.html#\1[\2]')
  end

  def versions_index_exists?(name, type)
    File.exist?("#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc")
  end

  def write_versions_index(name, type, versions)
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc"
    lazy_create_output_folder(output_asciidoc)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/plugin-index.asciidoc.erb"))
    content = template.result_with_hash(name: name, type: type, versions: versions)
    File.write(output_asciidoc, content)
  end

  def write_type_index(type, plugins)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/type.asciidoc.erb"))
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s-index.asciidoc"
    lazy_create_output_folder(output_asciidoc)
    content = template.result_with_hash(type: type, plugins: plugins)
    File.write(output_asciidoc, content)
  end

  def write_alias_index(type, alias_name, target)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/alias-index.asciidoc.erb"))
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{alias_name}-index.asciidoc"
    lazy_create_output_folder(output_asciidoc)
    content = template.result_with_hash(type: type, alias_name: alias_name, target: target)
    File.write(output_asciidoc, content)
  end

  def lazy_create_output_folder(file_name)
    directory = File.dirname(file_name)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
  end

  def fetch_stack_versions
    current_stack_versions = resolve_current_versions
    @stack_version = get_stack_version(current_stack_versions)
    puts "Stack version: #{@stack_version}\n"

    @ecs_version = get_ecs_version(current_stack_versions)
    puts "ECS version: #{@ecs_version}\n"
  end

  def fetch_stack_versions_doc(version)
    Net::HTTP.get(URI.parse(STACK_VERSIONS_BASE_URL + version + ".asciidoc"))
  end

  def resolve_current_versions
    current_stack_versions_ref_doc = fetch_stack_versions_doc("current")
    current_doc_link = current_stack_versions_ref_doc[/include::(.*?).asciidoc/m, 1]
    fetch_stack_versions_doc(current_doc_link)
  end

  def get_stack_version(stack_versions)
    get_major_and_minor_versions(stack_versions[/\:version:\s+(.*?)\n/, 1])
  end

  def get_ecs_version(stack_versions)
    get_major_and_minor_versions(stack_versions[/\:ecs_version:\s+(.*?)\n/, 1])
  end

  # In VPR documentation URLs, only major and minor versions are used.
  def get_major_and_minor_versions(full_version)
    raise "Stack version cannot be null." if full_version.nil?
    version = Gem::Version.new(full_version)
    version.segments.first().to_s + "." + version.segments[1].to_s
  end

  def write_stack_versions(content, type)
    # BRANCH and ECS_VERSION are newly added, will be available when every plugin index docs are re-indexed.
    # This is a backfill logic to add the fields after :type: entry
    if content =~ /\[":branch: %BRANCH%"\]/
      type_entry = ":type: #{type}\n"
      logstash_version_entry = ":branch: %BRANCH%\n"
      ecs_version_entry = ":ecs_version: %ECS_VERSION%\n"
      index = content.index(type_entry)
      index = index + type_entry.length
      content.insert(index, logstash_version_entry)
      content.insert(index + logstash_version_entry.length, ecs_version_entry)
    end

    content = content \
      .gsub("%BRANCH%", @stack_version) \
      .gsub("%ECS_VERSION%", @ecs_version)
  end

end

if __FILE__ == $0
  VersionedPluginDocs.run
end
