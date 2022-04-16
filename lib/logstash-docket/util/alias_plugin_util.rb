# encoding: utf-8

require "yaml"
require "net/http"

module LogstashDocket
  module Util
    ##
    # A util class defines repetitive logics for aliased plugins.
    #
    class AliasPluginUtil

      ALIAS_MAPPINGS_URL = 'https://raw.githubusercontent.com/elastic/logstash/master/logstash-core/src/main/resources/org/logstash/plugins/AliasRegistry.yml'

      def fetch_alias_mappings
        YAML::safe_load(Net::HTTP.get(URI(ALIAS_MAPPINGS_URL))) || {}
      end
    end
  end
end
