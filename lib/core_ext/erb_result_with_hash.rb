# encoding: utf-8

##
# ERB in Ruby 2.5 introduced `ERB#result_with_hash`, which allows a template
# to be rendered with a minimal binding based on explicit key/value hash in
# order to avoid leaking local context (including local variables, instance
# variables and methods, etc.).
#
# This patch back-ports the functionality when executed on Rubies < 2.5
# by providing a minimal binding based on a one-off Struct to the existing
# `ERB#result(binding)` method.
if RUBY_VERSION =~ %r{\A(?:1\.|2\.[0-4]\.)}
  require 'erb'

  class ERB
    ##
    # @param key_value_map [Hash{#to_sym=>Object}]
    # @return [String]
    def result_with_hash(key_value_map)
      minimal_binding = Struct.new(*key_value_map.keys.map(&:to_sym))
                              .new(*key_value_map.values)
                              .instance_exec { binding }
      self.result(minimal_binding)
    end
  end
end
