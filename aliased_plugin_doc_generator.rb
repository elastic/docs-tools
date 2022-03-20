
require "clamp"

require_relative 'lib/logstash-docket'

class AliasedPluginDocGenerator < Clamp::Command
  option "--path", "PATH", "The path aliased plugins located.", required: true
  option "--alias-type", "ALIAS_TYPE", "Type of the alias to generate a doc.", required: true

  ALIAS_PLUGINS = {
    "beats" => {
      "plugin_type" => "inputs",
      "files" => {
        "input_file" => "beats.asciidoc",
        "output_file" => "elastic_agent.asciidoc"
      },
      "replaces" => {
        ":plugin: beats" => ":plugin: elastic_agent",
        ":plugin-uc: Beats" => ":plugin-uc: Elastic Agent",
        ":plugin-singular: Beat" => ":plugin-singular: Elastic Agent"
      }
    }
  }

  def execute
    if ALIAS_PLUGINS.include?alias_type
      puts "Generating a doc for #{alias_type}.\n"

      file_path = path + "/" + ALIAS_PLUGINS[alias_type]["plugin_type"] + "/"
      input_file = file_path + ALIAS_PLUGINS[alias_type]["files"]["input_file"]
      output_file = file_path + ALIAS_PLUGINS[alias_type]["files"]["output_file"]

      puts "Input file: #{input_file}.\n"
      content = File.read(input_file)
      ALIAS_PLUGINS[alias_type]["replaces"].each { | key, value | content = content.gsub(key, value) }

      puts "Output file: #{output_file}.\n"
      File.write(output_file, content)
    else
      puts "Could not find a plugin for alias: #{alias_type}.\n"
    end
  end
end

if __FILE__ == $0
  AliasedPluginDocGenerator.run
end
