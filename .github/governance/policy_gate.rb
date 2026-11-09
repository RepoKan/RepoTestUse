# frozen_string_literal: true
require 'yaml'

module CodeRabbitPilot
  class Invalid < StandardError; end
  REQUIRED = %w[
    .coderabbit.config.ts .coderabbit.yaml .coderabbit.yml .github/**
    .github/workflows/** .github/CODEOWNERS .devcontainer/** .vscode/**
    .agents/** .copilot/** mcp_config.json AGENTS.md **/AGENTS.md CODEOWNERS
    docs/CODEOWNERS **/CODEOWNERS .gitmodules .npmrc **/.npmrc
    package.json **/package.json package-lock.json **/package-lock.json
    pnpm-lock.yaml **/pnpm-lock.yaml yarn.lock **/yarn.lock
    bun.lock **/bun.lock bun.lockb **/bun.lockb
  ].freeze
  APPROVAL_KEYS = %w[enabled allow_author_approval max_merge_risk max_security_risk overrides].freeze
  OVERRIDE_KEYS = %w[enabled paths teams max_merge_risk max_security_risk].freeze
  module_function

  def check(ok, message)
    raise Invalid, message unless ok
  end

  def inspect_node(node, depth = 0)
    check(depth < 33, 'YAML depth exceeded')
    check(!node.is_a?(Psych::Nodes::Alias), 'YAML aliases forbidden')
    check(!node.respond_to?(:anchor) || node.anchor.nil?, 'YAML anchors forbidden')
    check(!node.respond_to?(:tag) || node.tag.nil?, 'YAML explicit tags forbidden')
    if node.is_a?(Psych::Nodes::Mapping)
      seen = {}
      node.children.each_slice(2) do |key, value|
        check(key.is_a?(Psych::Nodes::Scalar), 'Scalar YAML keys required')
        check(key.value.match?(/\A[A-Za-z_][A-Za-z0-9_-]*\z/), 'Exact ASCII key required')
        check(!seen[key.value], "Duplicate YAML key: #{key.value}")
        seen[key.value] = true
        inspect_node(key, depth + 1)
        inspect_node(value, depth + 1)
      end
    elsif node.is_a?(Psych::Nodes::Scalar)
      if node.plain && node.value.match?(/\A(?:yes|no|on|off|true|false)\z/i)
        check(%w[true false].include?(node.value), 'Noncanonical boolean')
      end
    else
      (node.children || []).each { |child| inspect_node(child, depth + 1) }
    end
  end

  def parse(source)
    check(source.is_a?(String) && source.bytesize <= 131072, 'Size limit')
    data = source.dup.force_encoding(Encoding::UTF_8)
    check(data.valid_encoding?, 'Invalid UTF-8')
    stream = Psych.parse_stream(data)
    check(stream.children.length == 1, 'Exactly one YAML document required')
    check(stream.children.first.root.is_a?(Psych::Nodes::Mapping), 'Mapping root required')
    inspect_node(stream.children.first.root)
    YAML.safe_load(data, permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue Psych::Exception => e
    raise Invalid, "YAML parser rejected input: #{e.message}"
  end

  def mapping(value, label, keys = nil)
    check(value.is_a?(Hash) && value.keys.all? { |k| k.is_a?(String) }, "#{label} must be a mapping")
    check((value.keys - keys).empty?, "#{label} has unknown/mis-cased keys") if keys
    value
  end

  def exact(value, expected, label)
    check(value.class == expected.class && value == expected, "#{label} must be #{expected.inspect}")
  end

  def paths(value)
    check(value.is_a?(Array) && !value.empty?, 'Paths must be nonempty')
    check(value.all? { |p| p.is_a?(String) && !p.empty? && p == p.strip && !p.start_with?('!', '/') &&
      !p.include?('..') && !p.include?('\\') }, 'Invalid glob path')
    check(value.uniq.length == value.length, 'Duplicate glob paths')
  end

  def validate(source)
    c = mapping(parse(source), 'root')
    exact(c['inheritance'], false, 'inheritance') if c.key?('inheritance')
    review = mapping(c['reviews'], 'reviews')
    check((review.keys.grep(/approval|auto_review/i) - %w[auto_approvals auto_review]).empty?, 'Unknown review policy key')
    automatic = mapping(review['auto_review'], 'auto_review')
    exact(automatic['enabled'], true, 'auto_review.enabled')
    a = mapping(review['auto_approvals'], 'auto_approvals', APPROVAL_KEYS)
    exact(a['enabled'], true, 'auto_approvals.enabled')
    exact(a['allow_author_approval'], false, 'allow_author_approval')
    %w[max_merge_risk max_security_risk].each { |key| exact(a[key], 'low', key) }
    rules = a['overrides']
    check(rules.is_a?(Array) && !rules.empty?, 'Overrides must be nonempty')
    rules.each do |r|
      mapping(r, 'override', OVERRIDE_KEYS)
      exact(r['enabled'], false, 'override.enabled') if r.key?('enabled')
      check(r.key?('paths') || r.key?('teams'), 'Scoped override required')
      paths(r['paths']) if r.key?('paths')
      if r.key?('teams')
        check(r['teams'].is_a?(Array) && !r['teams'].empty? &&
          r['teams'].all? { |team| team.is_a?(String) && team.match?(/\A[A-Za-z0-9-]+\/[A-Za-z0-9-]+\z/) },
          'Invalid team scopes')
      end
      %w[max_merge_risk max_security_risk].each do |key|
        check(%w[minimal low].include?(r[key]), 'Override escalates risk') if r.key?(key)
      end
      check((r.fetch('paths', []) & %w[* ** **/*]).empty?, 'Overbroad automatic approval scope')
    end
    check(rules.any? { |r| r['enabled'].equal?(false) && !r.key?('teams') &&
      (REQUIRED - r.fetch('paths', [])).empty? }, 'Incomplete unconditional sensitive paths')
    true
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    raise CodeRabbitPilot::Invalid, 'Usage: ruby policy_gate.rb YAML' unless ARGV.length == 1
    path = ARGV[0]
    raise CodeRabbitPilot::Invalid, 'Regular file required' unless File.lstat(path).file?
    data = File.open(path, 'rb') { |f| f.read(131073) }
    CodeRabbitPilot.validate(data)
    puts 'PASS: checked-in CodeRabbit YAML policy (not human/merge authorization)'
  rescue CodeRabbitPilot::Invalid, SystemCallError => error
    warn "FAIL: #{error.message}"
    exit 1
  end
end
