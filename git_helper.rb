require "octokit"

class GitHelper

  attr_reader :git_client, :repo_name

  def initialize(repo_name)
    using_gh_token = "using a github token"
    if ENV.fetch("GITHUB_TOKEN", "").size > 0
      puts using_gh_token
    else
      puts "not ".concat(using_gh_token)
    end

    @git_client = Octokit::Client.new(:access_token => ENV["GITHUB_TOKEN"])

    fail("Repo name cannot be null or empty") if repo_name.nil? || repo_name.empty?
    @repo_name = repo_name
  end

  def commit(repo_path, branch_name, commit_msg)
    puts "Committing changes..."
    Dir.chdir(repo_path) do |path|
      `git checkout -b #{branch_name}`
      `git add .`
      `git commit -m "#{commit_msg}" -a`
      `git push origin #{branch_name}`
    end
  end

  def create_pull_request(branch_name, against_branch, title, description)
    puts "Creating a PR..."
    @git_client.create_pull_request(@repo_name, against_branch, branch_name, title, description)
  end

  def branch_exists?(branch_name)
    @git_client.branch(@repo_name, branch_name)
    true
  rescue Octokit::NotFound
    false
  end
end