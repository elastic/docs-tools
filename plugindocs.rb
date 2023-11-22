require "clamp"
require "fileutils"
require "json"
require "pmap" # Enumerable#peach
require "set"
require "stud/try"
require "time"
require "thread" # Mutex
require "yaml"

require_relative 'lib/logstash-docket'

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
  option "--main", :flag, "Fetch the plugin's docs from main instead of the version found in PLUGINS_JSON", :default => false
  option "--settings", "SETTINGS_YAML", "Path to the settings file.", :default => File.join(File.dirname(__FILE__), "settings.yml"), :attribute_name => :settings_path
  option("--parallelism", "NUMBER", "for performance", default: 4) { |v| Integer(v) }
  option "--skip-existing", :flag, "Don't generate documentation if asciidoc file exists"

  parameter "PLUGINS_JSON", "The path to the file containing plugin versions json"

  include LogstashDocket

  # cache the processed plugins to prevent re-process with wrapped and alias plugins
  @@processed_plugins = Set.new

  # a mutex to provide safely sharing resources in threads
  @@mutex = Mutex.new

  def execute
    settings = YAML.load(File.read(settings_path))

    report = JSON.parse(File.read(plugins_json))
    repositories = report["successful"]

    alias_definitions = Util::AliasDefinitionsLoader.get_alias_definitions

    # we need to sort to be sure we generate docs first for embedded plugins of integration plugins
    # and skip the process for stand-alone plugin if already processed
    sorted_repositories = repositories.sort_by { |name,_|  name.include?('-integration-') ? 0 : 1 }
    if parallelism > 1
      $stderr.puts("WARN: --parallelism is temporarily constrained to 1\n")
    end

    # there is a race condition when embedded plugins of integrations have changes
    # we are using cache mechanism to slightly improve the situation but doesn't 100% guarantee
    # TODO: for the long term stick with {.peach(parallelism) do |repository_name, details| }
    # to speed up the process
    # quick thought: separate integration embedded plugin doc generation process
    sorted_repositories.each do |repository_name, details|
      next if plugin_processed?(repository_name)
      cache_processed_plugin(repository_name)

      if settings['skip'].include?(repository_name)
        $stderr.puts("Skipping #{repository_name}\n")
        next
      end

      is_default_plugin = details["from"] == "default"
      version = main? ? nil : details['version']

      released_plugin = ArtifactPlugin.from_rubygems(repository_name, version) do |gem_data|
        github_source_from_gem_data(repository_name, gem_data)
      end || fail("[repository:#{repository_name}]: failed to find release package `#{tag(version)}` via rubygems")

      if released_plugin.type == 'integration' && !is_default_plugin
        $stderr.puts("[repository:#{repository_name}]: Skipping non-default Integration Plugin\n")
        next
      end

      release_tag = released_plugin.tag
      release_date = released_plugin.release_date ?
                       released_plugin.release_date.strftime("%Y-%m-%d") :
                       "unreleased"
      changelog_url = released_plugin.changelog_url

      released_plugin.with_wrapped_plugins(alias_definitions).each do |plugin|
        cache_processed_plugin(plugin.canonical_name)
        write_doc_to_file(plugin, release_tag, release_date, changelog_url, is_default_plugin)
      end
    end
  end

  private

  ##
  # Generates a doc based on plugin info and writes to output .asciidoc file.
  #
  # @param plugin [Plugin]
  # @param release_tag [String]
  # @param release_date [String]
  # @param changelog_url [String]
  # @param is_default_plugin [Boolean]
  # @return [void]
  def write_doc_to_file(plugin, release_tag, release_date, changelog_url, is_default_plugin)
    $stderr.puts("#{plugin.desc}: fetching documentation\n")
    content = plugin.documentation

    if content.nil?
      $stderr.puts("#{plugin.desc}: failed to fetch doc; skipping\n")
      return
    end

    output_asciidoc = "#{output_path}/docs/plugins/#{plugin.type}s/#{plugin.name}.asciidoc"
    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)

    # Replace %VERSION%, etc
    content = content \
      .gsub("%VERSION%", release_tag) \
      .gsub("%RELEASE_DATE%", release_date || "unreleased") \
      .gsub("%CHANGELOG_URL%", changelog_url)

    # Inject contextual variables for docs build
    injection_variables = Hash.new
    injection_variables[:default_plugin] = (is_default_plugin ? 1 : 0)
    content = inject_variables(content, injection_variables)

    # Even if no version bump, sometimes generating content might be different.
    # For this case, we skip to accept the changes.
    # eg: https://github.com/elastic/logstash-docs/pull/983/commits
    if skip_existing? && File.exist?(output_asciidoc) \
          && no_version_bump?(output_asciidoc, content)
      $stderr.puts("#{plugin.desc}: skipping since no version bump and doc exists.\n")
      return
    end

    # write the doc
    File.write(output_asciidoc, content)
    puts "#{plugin.canonical_name}@#{plugin.tag}: #{release_date}\n"
  end

  ##
  # Hack to inject variables after a known pattern (the type declaration)
  #
  # @param content [String]
  # @param kv [Hash{#to_s,#to_s}]
  # @return [String]
  def inject_variables(content, kv)
    kv_string = kv.map do |k, v|
      ":#{k}: #{v}"
    end.join("\n")

    content.sub(/^:type: .*/) do |type|
      "#{type}\n#{kv_string}"
    end
  end

  ##
  # Support for plugins that are sourced outside the logstash-plugins org,
  # by means of the gem_data's `source_code_uri` metadata.
  def github_source_from_gem_data(gem_name, gem_data)
    known_source = gem_data.dig('metadata', 'source_code_uri')

    if known_source
      known_source =~ %r{\bgithub.com/(?<org>[^/]+)/(?<repo>[^/]+)} || fail("unsupported source `#{known_source}`")
      org = Regexp.last_match(:org)
      repo = Regexp.last_match(:repo)
    else
      org = ENV.fetch('PLUGIN_ORG','logstash-plugins')
      repo = gem_name
    end

    Source::Github.new(org: org, repo: repo)
  end

  def tag(version)
    version ? "v#{version}" : "main"
  end

  ##
  # Checks if no version bump and return true if so, false otherwise.
  #
  # @param output_asciidoc [String]
  # @param content [String]
  # @return [Boolean]
  def no_version_bump?(output_asciidoc, content)
    existing_file_content = File.read(output_asciidoc)
    version_fetch_regex = /^\:version: (.*?)\n/
    existing_file_content[version_fetch_regex, 1] == content[version_fetch_regex, 1]
  end

  ##
  # Checks if plugin cached.
  #
  # @param plugin_canonical_name [String]
  # @return [Boolean]
  def plugin_processed?(plugin_canonical_name)
    @@mutex.synchronize do
      return @@processed_plugins.include?(plugin_canonical_name)
    end
  end

  ##
  # Adds a plugin to caching list.
  #
  # @param plugin_canonical_name [String]
  # @return [void]
  def cache_processed_plugin(plugin_canonical_name)
    @@mutex.synchronize do
      @@processed_plugins.add(plugin_canonical_name)
    end
  end
end

if __FILE__ == $0
  PluginDocs.run
end
