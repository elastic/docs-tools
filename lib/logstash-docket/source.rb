# encoding: utf-8

require 'set'

module LogstashDocket
  ##
  # A {@link Source} provides methods for working with versioned source data.
  #
  module Source
    ##
    # Read the file at the given version
    #
    # @param filename [String]: the full file path
    # @param version [#to_s, nil]: the version (default: latest)
    #
    # @return [String]
    def read_file(filename, version=nil)
      fail NotImplementedError
    end

    ##
    # Get the public web URL for the given file path at the given revision
    #
    # @param filename [String]: the full file path
    # @param version [#to_s, nil]: the version (default: latest)
    #
    # @return [String]
    def web_url(filename, version=nil)
      fail NotImplementedError
    end

    ##
    # Get a set of release tags from this source
    #
    # @return [Set{String}]
    def release_tags
      fail NotImplementedError
    end

    ##
    # A {@link Source::Github} represents the source of a public project hosted on Github
    class Github
      include Source

      attr_reader :org
      attr_reader :repo

      ##
      # @param repo [String]: a repository name
      # @param org [String]: a github organisation (default: extract from `repo`)
      # @param octokit [Octokit::Client]: a github API client (optional; required for tag listing)
      def initialize(repo:, org:nil, octokit: nil)
        if org.nil?
          org, repo = repo.split('/', 2)
          fail(ArgumentError, "incomplete repo spec: `#{repo}`") if org.nil? || repo.nil?
        end

        @org = org
        @repo = repo

        @octokit = octokit
      end

      ##
      # @see [Source#read_file]
      def read_file(filename, version=nil)
        uri = URI.parse("https://raw.githubusercontent.com/#{org}/#{repo}/#{ref(version)}/#{filename}")
        response = Net::HTTP.get(uri)

        return nil if response.start_with?('404: Not Found')

        response
      end

      ##
      # @see [Source#web_url]
      def web_url(filename, version=nil)
        "https://github.com/#{org}/#{repo}/blob/#{ref(version)}/#{filename}"
      end

      ##
      # @see [Source#release_tags]
      def release_tags
        @tags ||= begin
          fail('octokit github client required') if @octokit.nil?
          Set.new(@octokit.tags("#{org}/#{repo}").map(&:name).select{|t| t[%r{\Av\d+\.\d+\.\d+}] })
        end
      end

      private

      def ref(version)
        version ? "v#{version}" : 'master'
      end
    end
  end
end