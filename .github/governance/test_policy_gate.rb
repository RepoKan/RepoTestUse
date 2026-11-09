# frozen_string_literal: true
require 'minitest/autorun'
require 'yaml'
require_relative 'policy_gate'

class CodeRabbitPilotTest < Minitest::Test
  SOURCE = File.read(File.expand_path('../../.coderabbit.yaml', __dir__))
  BASE = YAML.safe_load(SOURCE)
  # Deliberately separate from the production constant.
  REQUIRED = %w[
    .coderabbit.config.ts .coderabbit.yaml .coderabbit.yml .github/**
    .github/workflows/** .github/CODEOWNERS .devcontainer/** .vscode/**
    .agents/** .copilot/** mcp_config.json AGENTS.md **/AGENTS.md CODEOWNERS
    docs/CODEOWNERS **/CODEOWNERS .gitmodules .npmrc **/.npmrc
    package.json **/package.json package-lock.json **/package-lock.json
    pnpm-lock.yaml **/pnpm-lock.yaml yarn.lock **/yarn.lock
    bun.lock **/bun.lock bun.lockb **/bun.lockb
  ].freeze

  def mutate
    c = Marshal.load(Marshal.dump(BASE))
    yield c, c.fetch('reviews').fetch('auto_approvals')
    YAML.dump(c)
  end

  def invalid(source)
    assert_raises(CodeRabbitPilot::Invalid) { CodeRabbitPilot.validate(source) }
  end

  def test_current_policy_and_required_paths
    assert_equal REQUIRED, CodeRabbitPilot::REQUIRED
    assert CodeRabbitPilot.validate(SOURCE)
  end

  def test_risk_limits_and_overrides
    %w[max_merge_risk max_security_risk].each do |key|
      ['moderate', 'high', 'critical', 'LOW', nil, true, 1, {}].each do |value|
        invalid(mutate { |_,a| a[key] = value })
        invalid(mutate { |_,a| a['overrides'] << {'paths' => ['README.md'], key => value} })
      end
      invalid(mutate { |_,a| a.delete(key) })
    end
  end

  def test_exclusions_and_author_gate
    REQUIRED.each { |path| invalid(mutate { |_,a| a['overrides'][0]['paths'].delete(path) }) }
    [true, nil, 1, 'false'].each { |v| invalid(mutate { |_,a| a['allow_author_approval'] = v }) }
    [false, nil, 0].each { |v| invalid(mutate { |_,a| a['enabled'] = v }) }
    invalid(mutate { |_,a| a['overrides'][0].delete('enabled') })
    invalid(mutate { |_,a| a['overrides'][0]['teams'] = ['sample/reviewers'] })
    invalid(mutate { |_,a| a['overrides'] << {'paths' => ['README.md'], 'enabled' => true} })
    invalid(mutate { |_,a| a['overrides'][0]['paths'] << '**' })
    invalid(mutate { |_,a| a['max_Security_Risk'] = 'low' })
    invalid(mutate { |c,_| c['inheritance'] = true })
  end

  def test_yaml_ambiguities
    invalid(SOURCE + "\nreviews: {}\n")
    invalid(SOURCE + "\n---\nreviews: {}\n")
    invalid(SOURCE.sub('reviews:', 'reviews: &policy'))
    invalid(SOURCE.sub('    max_merge_risk: low', '    max_merge_risk: !!str low'))
    invalid(SOURCE.sub('    max_merge_risk: low', "    max_merge_risk: high\n    max_merge_risk: low"))
  end
end
