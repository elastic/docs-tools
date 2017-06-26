require "clamp"
require "json"
require "fileutils"
require "time"
require "net/http"
require "stud/try"

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
  option "--master", :flag, "Fetch the plugin's docs from master instead of the version found in PLUGINS_JSON", :default => false
  parameter "PLUGINS_JSON", "The path to the file containing plugin versions json"

  def execute
    report = JSON.parse(File.read(plugins_json))
    plugins = report["successful"]

    skip = [ "logstash-core-plugin-api", "logstash-patterns-core", "logstash-devutils" ]
    skip += [ 
      "logstash-codec-sflow", # Empty plugin repository
      "logstash-filter-math", # Empty plugin repository
      "logstash-input-mongodb", # Empty plugin repository
      "logstash-filter-kubernetes_metadata", # https://github.com/logstash-plugins/logstash-filter-kubernetes_metadata/issues/2
      "logstash-input-eventlog", # https://github.com/logstash-plugins/logstash-input-eventlog/issues/38
    ]

    plugins.each do |repository, details|
      if skip.include?(repository)
        puts "Skipping #{repository}"
        next
      end

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

      File.write(output_asciidoc, content)
      puts "#{repository} #{version} (@ #{date})"
    end
  end

  def release_date(gem_name, version)
    uri = URI("https://rubygems.org/api/v1/versions/#{gem_name}.json")
    response = Stud::try(5.times) do
      r = Net::HTTP.get_response(uri)
      if !r.kind_of?(Net::HTTPSuccess)
        raise "Fetch rubygems metadata #{url} failed: #{r}"
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
