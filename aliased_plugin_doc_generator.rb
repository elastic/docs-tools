require "clamp"
require "yaml"

require_relative 'lib/logstash-docket'

class AliasedPluginDocGenerator < Clamp::Command
  option "--path", "PATH", "The path aliased plugins documents located.", required: true

  ALIAS_DEFINITION_URL = 'https://raw.githubusercontent.com/elastic/logstash/master/logstash-core/src/main/resources/org/logstash/plugins/AliasRegistry.yml'
  ASCII_DOC_EXTENSION = ".asciidoc"

  def execute
    aliased_plugins = load_alias_plugin_definition
    aliased_plugins.each do | type, alias_name, target |
      input_file = path + "/" + type + "s/" + target + ASCII_DOC_EXTENSION
      output_file = path + "/" + type + "s/" + alias_name + ASCII_DOC_EXTENSION

      copy_from_content = File.readlines(input_file)
      copy_to_content = File.readlines(output_file)

      # keep plugin header information
      (0..5).each { |i|
        copy_from_content[i] = copy_to_content[i]
      }

      File.open(output_file, 'w') { |f| f.write(copy_from_content.join) }
    end
  end

  def load_alias_plugin_definition
    alias_yml = Net::HTTP.get(URI(ALIAS_DEFINITION_URL))
    yaml = YAML::safe_load(alias_yml) || {}
    aliases = []

    yaml.each do |type, alias_defs|
      alias_defs.each do |alias_name, target|
        aliases << [type, alias_name, target]
      end
    end

    aliases
  end
end

if __FILE__ == $0
  AliasedPluginDocGenerator.run
end
