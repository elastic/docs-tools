require "clamp"
require "json"
require "fileutils"
require "net/http"

class PluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to the top-level of the logstash-docs path to write the output.", required: true
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

      #version = details["version"]
      #asciidoc_url = "https://github.com/logstash-plugins/#{repository}/blob/v#{version}/docs/index.asciidoc"
      #asciidoc_url = "https://github.com/logstash-plugins/#{repository}/blob/master/docs/index.asciidoc"
      version = "master"
      asciidoc_url = "https://raw.githubusercontent.com/logstash-plugins/#{repository}/#{version}/docs/index.asciidoc"

      uri = URI(asciidoc_url)
      response = Net::HTTP.get_response(uri)

      if !response.kind_of?(Net::HTTPSuccess)
        puts "Fetch of #{asciidoc_url} failed: #{response}"
        next
      end

      _, type, name = repository.split("-",3)
      output_asciidoc = "#{output_path}/docs/plugins/#{type}/#{name}.asciidoc"
      directory = File.dirname("#{output_path}/docs/plugins/#{type}/#{name}.asciidoc")
      FileUtils.mkdir_p(directory) if !File.directory?(directory)

      File.write(output_asciidoc, response.body) 
      puts repository
    end
  end
end

if __FILE__ == $0
  PluginDocs.run
end
