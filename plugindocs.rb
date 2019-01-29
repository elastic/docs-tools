require "clamp"
require "json"
require "fileutils"
require "time"
require "yaml"
require "net/http"
require "stud/try"

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
  option "--master", :flag, "Fetch the plugin's docs from master instead of the version found in PLUGINS_JSON", :default => false
  option "--settings", "SETTINGS_YAML", "Path to the settings file.", :default => File.join(File.dirname(__FILE__), "settings.yml"), :attribute_name => :settings_path
  parameter "PLUGINS_JSON", "The path to the file containing plugin versions json"

  def settings
    @settings ||= YAML.load(File.read(settings_path))
  end

  def execute
    report = JSON.parse(File.read(plugins_json))
    plugins = report["successful"]


    plugins.each do |repository, details|
      if settings["skip"].include?(repository)
        puts "Skipping #{repository}"
        next
      end

      is_default_plugin = details["from"] == "default"
      if master?
        version = "master"
        date = "unreleased"
      else
        version = "v" + details["version"]
        timestamp = release_date(repository, details["version"])
        date = timestamp.strftime("%Y-%m-%d")
      end

      asciidoc_url = "https://raw.githubusercontent.com/logstash-plugins/#{repository}/#{version}/docs/index.asciidoc"

      uri = URI(asciidoc_url)
      response = Net::HTTP.get_response(uri)

      if !response.kind_of?(Net::HTTPSuccess)
        puts "Fetch of #{asciidoc_url} failed: #{response}"
        next
      end

      _, type, name = repository.split("-",3)
      output_asciidoc = "#{output_path}/docs/plugins/#{type}s/#{name}.asciidoc"
      directory = File.dirname(output_asciidoc)
      FileUtils.mkdir_p(directory) if !File.directory?(directory)

      # Replace %VERSION%, etc
      content = response.body \
        .gsub("%VERSION%", version) \
        .gsub("%RELEASE_DATE%", date) \
        .gsub("%CHANGELOG_URL%", "https://github.com/logstash-plugins/#{repository}/blob/#{version}/CHANGELOG.md")

      content = content.sub(/^:type: .*/) do |type|
        # Mark default/non-default plugins so that the docs build will know to add the
        # "how to install this plugin" banner.
        if is_default_plugin
          "#{type}\n:default_plugin: 1"
        else
          "#{type}\n:default_plugin: 0"
        end
      end

      File.write(output_asciidoc, content)
      puts "#{repository} #{version} (@ #{date})"
    end
  end

  def release_date(gem_name, version)
    uri = URI("https://rubygems.org/api/v1/versions/#{gem_name}.json")
    response = Stud::try(5.times) do
      r = Net::HTTP.get_response(uri)
      if !r.kind_of?(Net::HTTPSuccess)
        raise "Fetch rubygems metadata #{uri} failed: #{r}"
      end
      r
    end

    body = response.body
    
    # HACK: One of out default plugins, the webhdfs, has a bad encoding in the
    # gemspec which make our parser trip with this error:
    #
    # Encoding::UndefinedConversionError message: ""\xC3"" from ASCII-8BIT to
    # UTF-8. We dont have much choice than to force utf-8.
    body.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)

    data = JSON.parse(body)

    current_version = data.select { |v| v["number"] == version }.first
    if current_version.nil?
      "N/A"
    else
      Time.parse(current_version["created_at"])
    end
  end
end

if __FILE__ == $0
  PluginDocs.run
end
