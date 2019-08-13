require "clamp"
require "json"
require "fileutils"
require "time"
require "yaml"
require "net/http"
require "stud/try"
require "pmap" # Enumerable#peach

require_relative 'lib/logstash-docket'

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
  option "--master", :flag, "Fetch the plugin's docs from master instead of the version found in PLUGINS_JSON", :default => false
  option "--settings", "SETTINGS_YAML", "Path to the settings file.", :default => File.join(File.dirname(__FILE__), "settings.yml"), :attribute_name => :settings_path
  option("--parallelism", "NUMBER", "for performance", default: 4) { |v| Integer(v) }

  parameter "PLUGINS_JSON", "The path to the file containing plugin versions json"

  include LogstashDocket

  def execute
    settings = YAML.load(File.read(settings_path))

    report = JSON.parse(File.read(plugins_json))
    repositories = report["successful"]

    repositories.peach(parallelism) do |repository_name, details|
      if settings['skip'].include?(repository_name)
        $stderr.puts("Skipping #{repository_name}\n")
        next
      end

      is_default_plugin = details["from"] == "default"
      version = master? ? nil : details['version']

      released_plugin = ArtifactPlugin.from_rubygems(repository_name, version) do |gem_data|
        github_source_from_gem_data(repository_name, gem_data)
      end || fail("[repository:#{repository_name}]: failed to find release package `#{tag(version)}` via rubygems")

      release_tag = released_plugin.tag
      release_date = released_plugin.release_date ?
                         released_plugin.release_date.strftime("%Y-%m-%d") :
                         "unreleased"
      changelog_url = released_plugin.changelog_url

      released_plugin.with_embedded_plugins.each do |plugin|
        $stderr.puts("#{plugin.desc}: fetching documentation\n")
        content = plugin.documentation

        if content.nil?
          $stderr.puts("#{plugin.desc}: failed to fetch doc; skipping\n")
          next
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

        # write the doc
        File.write(output_asciidoc, content)
        puts "#{plugin.canonical_name}@#{plugin.tag}: #{release_date}\n"
      end
    end
  end

  private

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
    if gem_name == "logstash-integration-rabbitmq"
      return Source::Github.new(org: "yaauie", repo: gem_name)
    end
    known_source = gem_data.dig('source_code_uri')

    if known_source
      known_source =~ %r{\bgithub\.com/(?<org>[^/])/(?<repo>[^/])} || fail("unsupported source `#{source}`")
      org = Regexp.last_match(:org)
      repo = Regexp.last_match(:repo)
    else
      org = ENV.fetch('PLUGIN_ORG','logstash-plugins')
      repo = gem_name
    end

    Source::Github.new(org: org, repo: repo)
  end

  def tag(version)
    version ? "v#{version}" : "master"
  end
end

if __FILE__ == $0
  PluginDocs.run
end
