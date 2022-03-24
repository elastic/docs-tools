# encoding: utf-8

require_relative 'plugin'

module LogstashDocket

  class AliasPlugin

    SUPPORTED_TYPES = Set.new(%w(input output filter codec).map(&:freeze)).freeze

    include Plugin

    attr_reader :canonical_plugin

    def initialize(canonical_plugin:, alias_name:)
      fail(ArgumentError) unless canonical_plugin.kind_of?(ArtifactPlugin)

      super(type: canonical_plugin.type, name: alias_name)

      fail("#{canonical_plugin.desc} plugin type #{type} not supported as an integration plugin") unless SUPPORTED_TYPES.include?(type)

      @canonical_plugin = canonical_plugin
    end

    ##
    # @see Plugin#version
    def version
      @canonical_plugin.version
    end

    def documentation
      content = @canonical_plugin.documentation

      # TODO: control the hard codings through central management for the long term
      # we had a discussion with Ry, we will manipulate these params through logstash repo AliasRegistry.yml
      # this will be covered by https://github.com/elastic/docs-tools/issues/69
      case name
      when "elastic_agent"
        replaces = {
          ":plugin: beats" => ":plugin: elastic_agent",
          ":plugin-uc: Beats" => ":plugin-uc: Elastic Agent",
          ":plugin-singular: Beat" => ":plugin-singular: Elastic Agent"
        }
        replaces.each { |key, value| content = content.gsub(key, value) }
      end

      content
    end

    ##
    # @see Plugin#release_date
    def release_date
      @canonical_plugin.release_date
    end

    ##
    # @see Plugin#changelog_url
    def changelog_url
      @canonical_plugin.changelog_url
    end

    ##
    # @see Plugin#tag
    def tag
      @canonical_plugin.tag
    end

    ##
    # @see Plugin#desc
    def desc
      @desc ||= "[plugin:#{canonical_name}@#{tag}]"
    end

    ##
    # @see Plugin#==
    def ==(other)
      return false unless super

      return false unless other.kind_of?(AliasPlugin)
      return false unless self.canonical_plugin == other.canonical_plugin

      return true
    end
  end
end