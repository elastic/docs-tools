# encoding: utf-8

require "yaml"
require "net/http"

module LogstashDocket
  module Util
    ##
    # A util class defines repetitive logics for aliased plugins.
    #
    class AliasDefinitionsLoader

      ALIAS_DEFINITIONS_URL = 'https://raw.githubusercontent.com/elastic/logstash/main/logstash-core/src/main/resources/org/logstash/plugins/AliasRegistry.yml'

      # Returns alias definitions for each plugin type ([type]=[alias_definitions])
      # ex: {
      #   "input" => [
      #     [{
      #       "alias" => "elastic_agent",
      #       "from" => "beats",
      #       "docs" => [{
      #         "replace" => ":plugin: beats",
      #         "with" => ":plugin: elastic_agent"
      #       }]
      #     }]
      #   ]
      # }
      def get_alias_definitions
        YAML::safe_load(Net::HTTP.get(URI(ALIAS_DEFINITIONS_URL))) || fail('empty alias definition')
      end
    end
  end
end
