# encoding: utf-8

require 'thread' # Mutex

module LogstashDocket
  module Util
    ##
    # A {@link ThreadsafeIndex} provides threadsafe get-or-set semantics using
    # the generator with which it was instantiated.
    class ThreadsafeIndex
      ##
      # @yieldparam key [Object]: the object for which to generate a value
      # @yieldreturn [Object]: the value henceforth to be used for the given key
      def initialize(&generator)
        @index = Hash.new
        @mutex = Mutex.new
        @generator = generator
      end

      ##
      # Fetches the value for the given key, potentially creating it using
      # the generator block provided at instantiation.
      #
      # @param key [Object]: the key object
      # @return [Object]
      def fetch(key)
        # attempt to fetch the value without acquiring a lock
        @index.fetch(key) do
          @mutex.synchronize do
            # return the value if it was set before we could
            # acquire the lock
            return @index.fetch(key) if @index.include?(key)

            @index.store(key, @generator.call(key))
          end
        end
      end

      ##
      # Iterate over the objects currently stored in the index without
      # generating more.
      #
      # @yieldparam key [Object]
      # @yieldparam value [Object]
      # @yieldreturn [void]
      def each
        return enum_for(:each) unless block_given?

        @mutex.synchronize { @index.to_a }.each do |key, value|
          yield key, value
        end
      end

      def each_value
        each.map(&:last)
      end

      def clear
        @mutex.synchronize { @index.clear }
      end
    end
  end
end
