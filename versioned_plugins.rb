require "clamp"
require "json"
require "fileutils"
require "time"
require "yaml"
require "net/http"
require "stud/try"
require "octokit"
require "erb"

class VersionedPluginDocs < Clamp::Command
  option "--output-path", "OUTPUT", "Path to a directory where logstash-docs repository will be cloned and written to", required: true
  option "--skip-existing", :flag, "Don't generate documentation if asciidoc file exists"
  option "--latest-only", :flag, "Only generate documentation for latest version of each plugin", :default => false
  option "--repair", :flag, "Apply several heuristics to correct broken documentation", :default => false
  option "--plugin-regex", "REGEX", "Only generate if plugin matches given regex", :default => "logstash-(?:codec|filter|input|output)"
  option "--dry-run", :flag, "Don't create a commit or pull request against logstash-docs", :default => false
  option "--test", :flag, "Clone docs repo and test generated docs", :default => false

  PLUGIN_SKIP_LIST = [
    "logstash-codec-example",
    "logstash-input-example",
    "logstash-filter-example",
    "logstash-output-example",
    "logstash-filter-script",
    "logstash-input-java_input_example",
    "logstash-filter-java_filter_example",
    "logstash-output-java_output_example",
    "logstash-codec-java_codec_example"
  ]

  def logstash_docs_path
    File.join(output_path, "logstash-docs")
  end

  def docs_path
    File.join(output_path, "docs")
  end

  attr_reader :octo

  def execute
    setup_github_client
    check_rate_limit!
    clone_docs_repo
    generate_docs
    if new_versions?
      if test?
        exit_status = test_docs
        if exit_status == 0 # success
          puts "success!"
        else
          puts "failed to build docs :("
          unless dry_run?
            puts "submitting PR for manual fixing."
            submit_pr
          end
          exit exit_status
        end
      end
      unless dry_run?
        puts "commiting to logstash-docs"
        commit
      end
    else
      puts "No new versions detected. Exiting.."
    end
  end

  def setup_github_client
    Octokit.auto_paginate = true
    if ENV.fetch("GITHUB_TOKEN", "").size > 0
      puts "using a github token"
    else
      puts "not using a github token"
    end
    @octo = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
  end

  def check_rate_limit!
    rate_limit = octo.rate_limit
    puts "Current GitHub rate limit: #{rate_limit.remaining}/#{rate_limit.limit}"
    if rate_limit.remaining < 100
      puts "Warning! Api rate limit is close to being reached, this script may fail to execute"
    end
  end

  def generate_docs
    regex = Regexp.new(plugin_regex)
    puts "writing to #{logstash_docs_path}"
    repos = octo.org_repos("logstash-plugins")
    repos = repos.map {|repo| repo.name }.select {|repo| repo.match(plugin_regex) }
    repos = (repos - PLUGIN_SKIP_LIST).sort.uniq

    puts "found #{repos.size} repos"
    repos_by_type = {}
    repos.each do |repo|
      _, type, name = repo.split("-",3)
      repos_by_type[type] ||= []
      repos_by_type[type] << repo
    end
    threads = repos_by_type.map do |type, repos|
      Thread.new { process_repos(octo, type, repos) }
    end
    threads.each(&:join)
  end

  def process_repos(octo, type, repos)
    repos_to_index = []
    puts "Looking for tags since the day before the last logstash-docs commit: #{$TIMESTAMP_REFERENCE}"
    repos.each do |repo|
      print "[#{repo}] looking for tags..."
      # with this header we avoid consuming from the github's rate limit quota if there are no new tags
      tags = octo.tags("logstash-plugins/#{repo}", :headers => { "If-Modified-Since" => $TIMESTAMP_REFERENCE})
      if tags.empty?
        puts "no new tags. skipping"
        _, _, name = repo.split("-",3)
        repos_to_index << name if versions_index_exists?(name, type)
        next
      else
        puts "found new tags (in total: #{tags.size} tags)"
      end

      begin
        release_info = fetch_release_info(repo)
      rescue
        puts "[#{repo}] failed to fetch data for #{repo}. skipping"
        next
      end
      versions = []
      tags = tags.map {|tag| tag.name}
                 .select {|tag| tag.match(/v\d+\.\d+\.\d+/) }
                 .sort_by {|tag| Gem::Version.new(tag[1..-1]) }
                 .reverse
      tags = tags.slice(0,1) if latest_only?
      tags.each do |tag|
        version = tag[1..-1]
        puts "[#{repo}] fetching docs for tag: #{tag} (version #{version}).."
        doc = fetch_doc(repo, tag)
        if doc.nil?
          puts "[#{repo}] couldn't find docs for tag #{tag}, skipping remaining tags.."
          break
        else
          begin
            timestamp = parse_release_date(release_info, version)
            date = timestamp.strftime("%Y-%m-%d")
            versions << [tag, date]
            expand_doc(doc, repo, tag, date)
          rescue => e
            puts "[#{repo}] failed to process release date for #{repo} #{tag}: #{e.inspect}"
          end
        end
      end
      if versions.any?
        _, _, name = repo.split("-",3)
        write_versions_index(name, type, versions)
        repos_to_index << name
      end
    end
    write_type_index(type, repos_to_index)
  end

  def clone_docs_repo
    `git clone git@github.com:elastic/logstash-docs.git #{logstash_docs_path}`
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout versioned_plugin_docs`
      last_commit_date = `git log -1 --date=short --pretty=format:%cd`
      $TIMESTAMP_REFERENCE=(Time.parse(last_commit_date) - 24*3600).strftime("%a, %d %b %Y %H:%M:%S %Z")
    end
  end

  def new_versions?
    Dir.chdir(logstash_docs_path) do |path|
      `git diff --name-status`
      `! git diff-index --quiet HEAD`
      $?.success?
    end
  end

  def submit_pr
    #branch_name = "versioned_docs_#{Time.now.strftime('%Y%m%d_%H%M%S')}"
    branch_name = "versioned_docs_failed_build"
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout -b #{branch_name}`
      `git add .`
      `git commit -m "updated versioned plugin docs" -a`
      `git push origin #{branch_name}`
    end
    octo = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])
    octo.create_pull_request("elastic/logstash-docs", "versioned_plugin_docs", branch_name,
        "auto generated update of versioned plugin documentation", "")
  end

  def commit
    Dir.chdir(logstash_docs_path) do |path|
      `git checkout versioned_plugin_docs`
      `git add .`
      `git commit -m "updated versioned plugin docs" -a`
      `git push origin versioned_plugin_docs`
    end
  end

  def test_docs
    puts "Cloning Docs repository"
    `git clone --depth 1 https://github.com/elastic/docs #{docs_path}`
    puts "Running docs build.."
    `#{docs_path}/build_docs --asciidoctor --respect_edit_url_overrides --doc #{logstash_docs_path}/docs/versioned-plugins/index.asciidoc --chunk 1`
    $?.exitstatus
  end

  def fetch_doc(repo, tag)
    response = Net::HTTP.get(URI.parse("https://raw.githubusercontent.com/logstash-plugins/#{repo}/#{tag}/docs/index.asciidoc"))
    if response =~ /404: Not Found/
      nil
    else
      response
    end
  end

  def expand_doc(doc, repository, version, date)
    _, type, name = repository.split("-",3)
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-#{version}.asciidoc"
    if File.exists?(output_asciidoc) && skip_existing?
      puts "skipping plugin #{repository} docs for version #{version}: file already exists"
      return
    end

    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)

    # Replace %VERSION%, etc
    content = doc \
      .gsub("%VERSION%", version) \
      .gsub("%RELEASE_DATE%", date) \
      .gsub("%CHANGELOG_URL%", "https://github.com/logstash-plugins/#{repository}/blob/#{version}/CHANGELOG.md") \
      .gsub(":include_path: ../../../../logstash/docs/include", ":include_path: ../include/6.x") \

    content = content.sub(/^:type: .*/) do |type|
      "#{type}"
    end

    content = content.sub(/^=== .+? #{type} plugin$/) do |header|
      "#{header} {version}"
    end

    if repair?
      content = content.gsub(/^====== /, "===== ")
        .gsub("[source]", "[source,shell]")
        .gsub('[id="plugins-{type}-{plugin}', '[id="plugins-{type}s-{plugin}')
        .gsub(":include_path: ../../../logstash/docs/include", ":include_path: ../include/6.x")

      content = content
        .gsub("<<string,string>>", "{logstash-ref}/configuration-file-structure.html#string[string]")
        .gsub("<<array,array>>", "{logstash-ref}/configuration-file-structure.html#array[array]")
        .gsub("<<number,number>>", "{logstash-ref}/configuration-file-structure.html#number[number]")
        .gsub("<<boolean,boolean>>", "{logstash-ref}/configuration-file-structure.html#boolean[boolean]")
        .gsub("<<hash,hash>>", "{logstash-ref}/configuration-file-structure.html#hash[hash]")
        .gsub("<<password,password>>", "{logstash-ref}/configuration-file-structure.html#password[password]")
        .gsub("<<path,path>>", "{logstash-ref}/configuration-file-structure.html#path[path]")
        .gsub("<<uri,uri>>", "{logstash-ref}/configuration-file-structure.html#uri[uri]")
        .gsub("<<bytes,bytes>>", "{logstash-ref}/configuration-file-structure.html#bytes[bytes]")
        .gsub("<<event-api,Event API>>", "{logstash-ref}/event-api.html[Event API]")
        .gsub("<<dead-letter-queues>>", '{logstash-ref}/dead-letter-queues.html[dead-letter-queues]')
        .gsub("<<logstash-config-field-references>>", "{logstash-ref}/event-dependent-configuration.html#logstash-config-field-references[Field References]")
    end

    content = content.gsub('[id="plugins-', '[id="{version}-plugins-')
      .gsub("<<plugins-{type}s-common-options>>", "<<{version}-plugins-{type}s-{plugin}-common-options>>")
      .gsub("<<plugins-{type}-{plugin}", "<<plugins-{type}s-{plugin}")
      .gsub("<<plugins-{type}s-{plugin}", "<<{version}-plugins-{type}s-{plugin}")
      .gsub("<<plugins-#{type}s-#{name}", "<<{version}-plugins-#{type}s-#{name}")
      .gsub("[[dlq-policy]]", '[id="{version}-dlq-policy"]')
      .gsub("<<dlq-policy>>", '<<{version}-dlq-policy>>')

    if repair?
      content.gsub!(/<<plugins-.+?>>/) do |link|
        match = link.match(/<<plugins-(?<link_type>\w+)-(?<link_name>\w+)(?:,(?<link_text>.+?))?>>/)
        if match.nil?
          link
        else
          if match[:link_type] == "#{type}s" && match[:link_name] == name
            # do nothing. it's an internal link
            link
          else
            # it's an external link. let's convert it
            if match[:link_text].nil?
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_name]} #{match[:link_type][0...-1]} plugin]"
            else
              "{logstash-ref}/plugins-#{match[:link_type]}-#{match[:link_name]}.html[#{match[:link_text]}]"
            end
          end
        end
      end

      match = content.match(/\[id="{version}-plugins-{type}s-{plugin}-common-options"\]/)
      if match.nil? && type != "codec"
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]",
                     "[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]")
      end

      if type == "codec"
        content = content.sub("This plugin supports the following configuration options plus the <<{version}-plugins-{type}s-{plugin}-common-options>> described later.\n", "")
        content = content.sub("Also see <<{version}-plugins-{type}s-{plugin}-common-options>> for a list of options supported by all\ncodec plugins.\n", "")
        content = content.sub("\n[id=\"{version}-plugins-{type}s-{plugin}-common-options\"]\ninclude::{include_path}/{type}.asciidoc[]", "")
        content = content.sub("\ninclude::{include_path}/{type}.asciidoc[]", "")
      end
    end

    File.write(output_asciidoc, content)
    puts "#{repository} #{version} (@ #{date})"
    true
  end

  def fetch_release_info(gem_name)
    uri = URI("https://rubygems.org/api/v1/versions/#{gem_name}.json")
    response = Stud::try(5.times) do
      r = Net::HTTP.get_response(uri)
      if r.kind_of?(Net::HTTPSuccess)
        r
      elsif r.kind_of?(Net::HTTPNotFound)
        nil
      else
        raise "Fetch rubygems metadata #{uri} failed: #{r}"
      end
    end

    body = response.body
    
    # HACK: One of out default plugins, the webhdfs, has a bad encoding in the
    # gemspec which make our parser trip with this error:
    #
    # Encoding::UndefinedConversionError message: ""\xC3"" from ASCII-8BIT to
    # UTF-8. We dont have much choice than to force utf-8.
    body.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)

    data = JSON.parse(body)
  end

  def parse_release_date(data, version)
    current_version = data.select { |v| v["number"] == version }.first
    if current_version.nil?
      "N/A"
    else
      Time.parse(current_version["created_at"])
    end
  end

  def versions_index_exists?(name, type)
    File.exist?("#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc")
  end

  def write_versions_index(name, type, versions)
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc"
    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/plugin-index.asciidoc.erb"))
    content = template.result(binding)
    File.write(output_asciidoc, content)
  end

  def write_type_index(type, plugins)
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/type.asciidoc.erb"))
    output_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s-index.asciidoc"
    directory = File.dirname(output_asciidoc)
    FileUtils.mkdir_p(directory) if !File.directory?(directory)
    content = template.result(binding)
    File.write(output_asciidoc, content)
  end
end

if __FILE__ == $0
  VersionedPluginDocs.run
end
