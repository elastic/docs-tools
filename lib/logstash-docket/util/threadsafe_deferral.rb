# encoding: utf-8

require 'thread' # Mutex

module LogstashDocket
  module Util
    ##
    # A {@link ThreadsafeDeferral} ensures that the provided block is
    # executed at-most-once, if and when the value of the deferral is
    # requested.
    class ThreadsafeDeferral
      ##
      # Captures the block for later execution if and when its value is requested.
      #
      # @yieldreturn [Object]
      def self.for(&generator)
        new(generator)
      end
      private_class_method :new

      def initialize(generator)
        @generator = generator
        @generated = false
        @result = nil
        @mutex = Mutex.new
      end

      ##
      # returns the value of this deferral, generating it if necessary
      #
      # @return [Object]
      def value
        # return the value if it has been generated,
        # or attempt to generate it.
        @generated ? @result : @mutex.synchronize do
          # return the value if the value was generated before
          # we acquired the lock (e.g., another thread won)
          @generated ? @result :  begin
            result = @generator.call
            @generator = nil
            @generated = true
            @result = result
          end
        end
      end
    end
  end
end