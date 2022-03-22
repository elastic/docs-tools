require "clamp"
require "yaml"

require_relative 'lib/logstash-docket'

class AliasedPluginDocGenerator < Clamp::Command
  option "--path", "PATH", "The path aliased plugins documents located.", required: true

  ALIAS_DEFINITION_URL = 'https://raw.githubusercontent.com/elastic/logstash/master/logstash-core/src/main/resources/org/logstash/plugins/AliasRegistry.yml'

  def execute
    aliased_plugins = load_alias_plugin_definition
    aliased_plugins.each do | type, alias_name, target |
      input_file_path = "#{path}/docs/plugins/#{type}s/#{target}.asciidoc"
      output_file_path = "#{path}/docs/plugins/#{type}s/#{alias_name}.asciidoc"
      copy_from_content = File.readlines(input_file_path)
      copy_to_content = File.readlines(output_file_path)

      # keep plugin header information
      (0..5).each { |i|
        copy_from_content[i] = copy_to_content[i]
      }

      File.open(output_file_path, 'w') { |f| f.write(copy_from_content.join) }
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
