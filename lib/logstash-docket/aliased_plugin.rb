# encoding: utf-8

require_relative 'plugin'

module LogstashDocket

  class AliasPlugin

    SUPPORTED_TYPES = Set.new(%w(input output filter codec).map(&:freeze)).freeze

    include Plugin

    attr_reader :canonical_plugin, :doc_headers

    def initialize(canonical_plugin:, alias_name:, doc_headers:)
      fail(ArgumentError) unless canonical_plugin.kind_of?(ArtifactPlugin)

      super(type: canonical_plugin.type, name: alias_name)

      fail("#{canonical_plugin.desc} plugin type #{type} not supported as an integration plugin") unless SUPPORTED_TYPES.include?(type)

      @canonical_plugin = canonical_plugin
      @doc_headers = doc_headers
    end

    ##
    # @see Plugin#version
    def version
      @canonical_plugin.version
    end

    def documentation
      content = @canonical_plugin.documentation
      @doc_headers.each { |header| content = content.gsub(header["replace"], header["with"]) }
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