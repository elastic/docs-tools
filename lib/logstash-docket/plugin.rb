# encoding: utf-8

module LogstashDocket
  ##
  # A {@link Plugin} represents a versioned release of a Logstash Plugin.
  #
  # It provides metadata about the plugin version and methods for retrieving
  # plugin documentation from its {@link Repository}.
  #
  # There are two implementations of this interface module:
  #
  #  - {@link ArtifactPlugin}, representing traditional plugins backed directly
  #    by a named and versioned artifact on rubygems.org, AND
  #  - {@link EmbeddedPlugin}, representing plugins that are packaged _inside_
  #    an "integration" {@link ArtifactPlugin}.
  #
  module Plugin

    ##
    # @api private
    #
    # @param type [String]
    # @param name [String]
    def initialize(type:, name:)
      @type = type
      @name = name

      @canonical_name = "logstash-#{type}-#{name}"
    end

    ##
    # @return [String]
    attr_reader :name

    ##
    # @return [String]
    attr_reader :type

    ##
    # @return [String]
    attr_reader :canonical_name

    ##
    # @return [Gem::Version]
    def version
      fail NotImplementedError
    end

    ##
    # @return [Time,nil]
    def release_date
      fail NotImplementedError
    end

    ##
    # @return [String]
    def changelog_url
      fail NotImplementedError
    end

    ##
    # @return [String]
    def tag
      fail NotImplementedError
    end

    ##
    # @return [String]
    def documentation
      fail NotImplementedError
    end

    ##
    # A string suitable for describing this {@link Plugin} in log messages
    #
    # @return [String]
    def desc
      fail NotImplementedError
    end

    def with_alias(alias_mappings)
      yield self

      if alias_mappings.include?(type) && alias_mappings[type].include?(name)
        yield AliasPlugin.new(canonical_plugin: self, alias_name: alias_mappings[type][name])
      end
    end

    ##
    # @return [Boolean]
    def ==(other)
      return false unless other.kind_of?(Plugin)

      return false unless self.type == other.type
      return false unless self.name == other.name
      return false unless self.version == other.version

      true
    end
  end
end