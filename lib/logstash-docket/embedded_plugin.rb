# encoding: utf-8

require_relative 'plugin'

module LogstashDocket
  ##
  # A {@link EmbeddedPlugin} is a {@link Plugin} that is provided within
  # an {@link ArtifactPlugin} "integration" plugin.
  #
  # @api semiprivate (@see ArtifactPlugin#embedded_plugins)
  class EmbeddedPlugin
    SUPPORTED_TYPES = Set.new(%w(input output filter codec).map(&:freeze)).freeze

    include Plugin

    ##
    # Returns the {@link ArtifactPlugin} that embedded this {@link EmbeddedPlugin}.
    #
    # @return [ArtifactPlugin]
    attr_reader :artifact_plugin

    ##
    # @see Plugin#initialize
    #
    # @param artifact_plugin [ArtifactPlugin]
    def initialize(artifact_plugin:, **args)
      fail(ArgumentError) unless artifact_plugin.kind_of?(ArtifactPlugin)

      super(**args)

      fail("#{artifact_plugin.desc} plugin type #{type} not supported as a wrapped plugin") unless SUPPORTED_TYPES.include?(type)

      @artifact_plugin = artifact_plugin
    end

    ##
    # @see Plugin#version
    def version
      @artifact_plugin.version
    end

    ##
    # @see Plugin#documentation
    def documentation
      @artifact_plugin.repository.read_file("docs/#{type}-#{name}.asciidoc", version)
    end

    ##
    # @see Plugin#release_date
    def release_date
      @artifact_plugin.release_date
    end

    ##
    # @see Plugin#changelog_url
    def changelog_url
      @artifact_plugin.changelog_url
    end

    ##
    # @see Plugin#tag
    def tag
      @artifact_plugin.tag
    end

    ##
    # @see Plugin#desc
    def desc
      @desc ||= "[plugin:#{artifact_plugin.canonical_name}/#{canonical_name}@#{tag}]"
    end

    ##
    # @see Plugin#==
    def ==(other)
      return false unless super

      return false unless other.kind_of?(EmbeddedPlugin)
      return false unless self.artifact_plugin == other.artifact_plugin

      return true
    end
  end
end