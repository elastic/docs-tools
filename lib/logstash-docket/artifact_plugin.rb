# encoding: utf-8

require_relative 'embedded_plugin'
require_relative 'aliased_plugin'
require_relative 'plugin'
require_relative 'repository'
require 'set'

module LogstashDocket

  ##
  # An {@link ArtifactPlugin} is an implementation of {@link Plugin} that
  # is used to represent plugins that are directly available by name on
  # rubygems.org.
  #
  # It can be used to represent self-contained plugins:
  #  - filter,
  #  - input,
  #  - output, OR
  #  - codec.
  #
  # It can also be used to represent top-level "integration" plugins that
  # themselves contain multiple "embedded" plugins (e.g., {@link EmbeddedPlugin}).
  #
  # @api public
  class ArtifactPlugin

    include Plugin

    ##
    # Attempts to instantiate an {@link ArtifactPlugin} from the named gem, using
    # the optionally-provided version as a hint.
    #
    # @param gem_name [String]
    # @param version [String, nil]: (optional: when omitted, source's main will
    #                               be used with the latest-available published gem metadata)
    #
    # @yieldparam [Hash{String=>Object}]: gem metadata
    # @yieldreturn [Source]
    #
    # @return [ArtifactPlugin,nil]
    def self.from_rubygems(gem_name, version=nil, &source_generator)
      repository = Repository.from_rubygems(gem_name, version, &source_generator)
      repository && repository.released_plugin(version)
    end

    SUPPORTED_TYPES = Set.new(%w(input output filter codec integration).map(&:freeze)).freeze
    EMPTY = Array.new.freeze
    VALID_PLUGIN_CAPTURING_TYPE_AND_NAME = %r{\Alogstash-(?<type>[a-z]+)-(?<name>.\w+)}

    ##
    # @see Plugin#repository
    attr_reader :repository

    ##
    # @see Plugin#version
    attr_reader :version

    ##
    # @see Plugin#initialize
    #
    # @param repository [Repository]
    # @param version [String]
    def initialize(repository:,version:)
      if repository.name !~ VALID_PLUGIN_CAPTURING_TYPE_AND_NAME
        fail(ArgumentError, "invalid plugin name `#{repository.name}`")
      end
      super(type: Regexp.last_match(:type), name: Regexp.last_match(:name))

      fail("#{desc} plugin type #{type} not supported as a top-level plugin") unless SUPPORTED_TYPES.include?(type)

      @repository = repository
      @version = version && Gem::Version.new(version)

      @embedded_plugins = Util::ThreadsafeDeferral.for(&method(:generate_embedded_plugins))
    end

    ##
    # @see Plugin#release_date
    def release_date
      version && repository.release_date(version)
    end

    ##
    # @see Plugin#documentation
    def documentation
      repository.read_file("docs/index.asciidoc", version)
    end

    ##
    # @see Plugin#changelog_url
    def changelog_url
      repository.web_url("CHANGELOG.md", version)
    end

    ##
    # @see Plugin#tag
    def tag
      version ? "v#{version}" : "main"
    end

    ##
    # @see Plugin#desc
    def desc
      @desc ||= "[plugin:#{canonical_name}@#{tag}]"
    end

    ##
    # Returns an {@link Enumerable[Plugin]} containing itself and any integrated plugins
    #
    # @return [Enumerable[Plugin]]
    def with_embedded_plugins
      return enum_for(:with_embedded_plugins) unless block_given?

      yield self

      embedded_plugins.each do |embedded_plugin|
        yield embedded_plugin
      end
    end

    ##
    # Returns an {@link Enumerable[Plugin]} containing itself and any wrapped plugins,
    # including integration-wrapped plugins and aliases from the provided mappings
    #
    def with_wrapped_plugins(alias_definitions)
      return enum_for(:with_wrapped_plugins, alias_definitions) unless block_given?

      with_embedded_plugins do |plugin|
        plugin.with_alias(alias_definitions) do |plugin_or_alias|
          yield plugin_or_alias
        end
      end
    end

    ##
    # Returns zero or more {@link Plugin::Wrapped} provided by
    # an "integration" plugin.
    #
    def embedded_plugins
      @embedded_plugins.value
    end

    ##
    # @see Plugin#==
    def ==(other)
      return false unless super

      return false unless other.kind_of?(ArtifactPlugin)

      return false unless self.repository == other.repository

      return true
    end

    private

    ##
    # @api private
    #
    # @return [Array[EmbeddedPlugin]]: a frozen array of {@link EmbeddedPlugin}
    def generate_embedded_plugins
      gem_data_version = version || repository.rubygem_info.latest
      gem_data_version || fail("No releases on rubygems")

      rubygem_info = repository.rubygem_info.for_version(gem_data_version) || fail("[#{desc}]: no gem data available")

      embedded_plugin_canonical_names_csv = rubygem_info.dig('metadata','integration_plugins')
      return EMPTY if embedded_plugin_canonical_names_csv.nil?

      embedded_plugin_canonical_names_csv.split(',').map(&:strip).map do |wrapped_canonical_name|
        if wrapped_canonical_name !~ %r{\Alogstash-(?<type>[a-z]+)-(?<name>.*)}
          fail(ArgumentError "unsupported plugin name `#{canonical_name}`")
        end
        EmbeddedPlugin.new(artifact_plugin: self, type: Regexp.last_match(:type), name: Regexp.last_match(:name))
      end.freeze
    end
  end
end
