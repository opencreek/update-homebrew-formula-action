#!/usr/bin/env ruby

# frozen_string_literal: true

require "bundler"
Bundler.require

require "base64"
require "digest"
require "logger"
require "optparse"
require "tempfile"

logger = Logger.new($stdout)
logger.level = Logger::WARN

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: entrypoint.rb [options]"

  opts.on("-r ", "--repository REPOSITORY", "The project repository") do |repository|
    options[:repository] = repository
  end

  opts.on("-t", "--tap REPOSITORY", "The Homebrew tap repository") do |repository|
    options[:tap] = repository
  end

  opts.on("-n", "--name NAME", "The name of the formula in Homebrew") do |repository|
    options[:name] = repository
  end

  opts.on("-f", "--formula PATH", "The path to the formula in the tap repository") do |path|
    options[:formula] = path
  end

  opts.on("-m", "--message MESSAGE", "The message of the commit updating the formula") do |message|
    options[:message] = message.strip
  end

  opts.on_tail("-v", "--verbose", "Output more information") do
    logger.level = Logger::DEBUG
  end

  opts.on_tail("-h", "--help", "Display this screen") do
    puts opts
    exit 0
  end
end.parse!

begin
  raise "GH_PERSONAL_ACCESS_TOKEN environment variable is not set" unless ENV["GH_PERSONAL_ACCESS_TOKEN"]

  raise "missing argument: -r/--repository" unless options[:repository]
  raise "missing argument: -t/--tap" unless options[:tap]
  raise "missing argument: -f/--formula" unless options[:formula]

  Octokit.middleware = Faraday::RackBuilder.new do |builder|
    builder.use Faraday::Request::Retry, exceptions: [Octokit::ServerError]
    builder.use Faraday::Response::RaiseError
    builder.use Octokit::Middleware::FollowRedirects
    builder.use Octokit::Response::FeedParser
    builder.response :logger, logger, log_level: :debug do |logger|
      logger.filter(/(Authorization\: )(.+)/, '\1[REDACTED]')
    end
    builder.adapter Faraday.default_adapter
  end

  client = Octokit::Client.new(access_token: ENV["GH_PERSONAL_ACCESS_TOKEN"])
  repo = client.repo(options[:repository])

  releases = repo.rels[:releases].get.data
  raise "No releases found" unless (latest_release = releases.first)

  tags = repo.rels[:tags].get.data
  unless (tag = tags.find { |t| t.name == latest_release.tag_name })
    raise "Tag #{latest_release.tag_name} not found"
  end

  formula_name = repo.name
  if options[:name]
    formula_name = options[:name]
  end
  PATTERN = /#{Regexp.quote(formula_name)}-#{Regexp.quote(latest_release.tag_name.delete_prefix("v"))}\.(?<platform>[^.]+)\.bottle\.((?<rebuild>[\d]+)\.)?tar\.gz/.freeze

  assets = {}
  rebuild = nil
  latest_release.assets.each do |asset|
    next unless (matches = asset.name.match(PATTERN))
    next unless (platform = matches[:platform])

    if rebuild && matches[:rebuild] && rebuild != matches[:rebuild]
      logger.warn "Rebuild number for #{platform} (#{matches[:rebuild]}) doesn't match previously declared value (#{rebuild}), ignoring"
    else
      logger.info "Found rebuild number #{matches[:rebuild]} for #{platform}"
      rebuild = rebuild || matches[:rebuild]
    end

    assets[platform] = Digest::SHA256.hexdigest(client.get(asset.browser_download_url))
  end

  blob = client.contents(options[:tap], path: options[:formula])
  original_formula = Base64.decode64(blob.content)

  buffer = Parser::Source::Buffer.new(original_formula, 1, source: original_formula)
  builder = RuboCop::AST::Builder.new
  ast = Parser::CurrentRuby.new(builder).parse(buffer)
  rewriter = Parser::Source::TreeRewriter.new(buffer)

  rewriter.transaction do
    if (version = ast.descendants.find { |d| d.send_type? && d.method_name == :version })
      rewriter.replace version.loc.expression, %Q(version "#{latest_release.tag_name}")
    end

    if (url = ast.descendants.find { |d| d.send_type? && d.method_name == :url })
      rewriter.replace url.loc.expression,
                       %Q(url "#{repo.clone_url}", tag: "#{latest_release.tag_name}", revision: "#{tag.commit.sha}")
    end

    root_url = "https://github.com/#{repo.owner.login}/#{repo.name}/releases/download/#{latest_release.tag_name}"

    bottles = assets.map do |platform, checksum|
      %Q(sha256 cellar: :any, #{platform}: "#{checksum}")
    end

    bottle_expression = <<~RUBY
      bottle do
        root_url "#{root_url}"
  #{"      rebuild #{rebuild}" if rebuild}
        #{bottles.join("\n    ")}
      end
    RUBY

    if (bottle = ast.descendants.find { |d| d.block_type? && d.send_node&.method_name == :bottle })
      if assets.empty?
        rewriter.replace bottle.loc.expression, ""
      else
        rewriter.replace bottle.loc.expression, bottle_expression
      end
    elsif assets.any?
      for node_name in %i[license url] do      
        (insert_after = ast.descendants.find { |d| d.send_type? && d.method_name == node_name })
        rewriter.insert_after insert_after.loc.expression, "\n\n#{bottle_expression}"
        break
      end
    end
  end

  updated_formula = rewriter.process
  begin
    tempfile = Tempfile.new("#{repo.name}.rb")
    File.write tempfile, updated_formula

    rubocop_config = "/Homebrew/Library/.rubocop.yml"
    raise "Can't find rubocop config: #{rubocop_config}" unless File.exist?(rubocop_config)
    logger.debug `rubocop -c #{rubocop_config} -x #{tempfile.path}`
    updated_formula = File.read(tempfile)
  ensure
    tempfile.close
    tempfile.unlink
  end

  logger.info updated_formula

  if original_formula == updated_formula
    logger.warn "Formula is up-to-date"
    exit 0
  else
    commit_message = options[:message].empty? ? "Update #{formula_name} to #{latest_release.tag_name}" : options[:message]
    logger.info commit_message
    client.update_contents(options[:tap],
                           options[:formula],
                           commit_message,
                           blob.sha,
                           updated_formula)
  end
rescue => e
  logger.fatal(e)
  exit 1
end
