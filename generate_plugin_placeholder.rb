require "clamp"
require "erb"
require "octokit"
require_relative "git_helper"

class GeneratePluginPlaceholder < Clamp::Command
  option "--output-path", "OUTPUT", "Path to a directory where logstash-docs repository will be cloned and written to", required: true
  option "--plugin-type", "STRING", "Type (ex: integration, input, etc) of a new plugin.", required: true
  option "--plugin-name", "STRING", "Name for a new plugin.", required: true

  SUPPORTED_TYPES = %w(integration)

  def execute
    generate_placeholder(plugin_type, plugin_name)
    submit_pr
  end

  # adds an empty static page under the VPR
  # this helps us to eliminate broken link issues in the docs
  def generate_placeholder(type, name)
    if type.nil? || name.nil?
      $stderr.puts("Plugin type and name are required.")
      return
    end

    unless SUPPORTED_TYPES.include?(type)
      $stderr.puts("#{type} is not supported. Supported types are #{SUPPORTED_TYPES.inspect}")
      return
    end

    placeholder_asciidoc = "#{logstash_docs_path}/docs/versioned-plugins/#{type}s/#{name}-index.asciidoc"
    # changing template will fail to re-index the doc, do not change or keep consistent with VPR templates
    template = ERB.new(IO.read("logstash/templates/docs/versioned-plugins/plugin-index.asciidoc.erb"))
    content = template.result_with_hash(name: name, type: type, versions: [])
    File.write(placeholder_asciidoc, content)
  end

  def logstash_docs_path
    File.join(output_path, "logstash-docs")
  end

  def submit_pr
    branch_name = "new_plugin_placeholder"
    git_helper = GitHelper.new("elastic/logstash-docs")
    if git_helper.branch_exists?(branch_name)
      puts "WARNING: Branch \"#{branch_name}\" already exists. Rejecting PR create process. Please merge the existing PR or delete the PR and the branch."
      return
    end

    pr_title = "A placeholder for new plugin"
    git_helper.commit(logstash_docs_path, branch_name, "create an empty placeholder for new plugin")
    git_helper.create_pull_request(branch_name, "versioned_plugin_docs", pr_title, "")
  end
end

if __FILE__ == $0
  GeneratePluginPlaceholder.run
end