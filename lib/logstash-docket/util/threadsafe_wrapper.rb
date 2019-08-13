# encoding: utf-8

require 'monitor'

module LogstashDocket
  module Util
    ##
    # A {@link ThreadsafeWrapper} ensures all access to
    # the wrapped object is thread-safe.
    class ThreadsafeWrapper
      def self.for(object)
        new(object)
      end
      private_class_method :new

      def initialize(object)
        @object = object
        @monitor = Mutex.new
      end

      def method_missing(method, *args, &block)
        @monitor.synchronize do
          @object.public_send(method, *args, &block)
        end
      end

      def respond_to_missing?(method, include_private = false)
        @monitor.synchronize do
          @object.respond_to?(method, include_private)
        end
      end
    end
  end
end