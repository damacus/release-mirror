#!/usr/bin/env ruby
# Keep the behaviour check present on docs-only PRs without running app tests.
require 'open3'

def git!(*arguments)
  output, error, status = Open3.capture3('git', *arguments)
  abort error unless status.success?
  output
end

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')
abort 'Expected commit SHAs.' unless [base, head].all? { |sha| /\A[0-9a-f]{40}\z/.match?(sha) }

paths = if base == '0' * 40
          git!('ls-tree', '-r', '--name-only', '-z', head).split("\0")
        else
          git!('diff', '--no-renames', '--name-only', '-z', base, head).split("\0")
        end

application = paths.any? do |path|
  !path.start_with?('docs/', 'openspec/') &&
    !%w[README.md AGENTS.md LICENSE LICENSE.md .github/workflows/docs.yaml].include?(path)
end

File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') { |file| file.puts "application=#{application}" }
puts(application ? 'Application inputs changed.' : 'Documentation-only change; application verification is skipped.')
