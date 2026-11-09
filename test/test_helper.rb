ENV['RACK_ENV'] = 'test'
ENV['TEST_SESSION_SECRET'] = 's' * 96
require 'minitest/autorun'
require 'rack/test'
require 'tmpdir'
require_relative '../lib/release_mirror/app'

module Fixtures
  ADMIN = {'kind' => 'human', 'issuer' => 'https://identity.example.test', 'subject' => 'operator'}.freeze
  HUMAN = {'kind' => 'human', 'issuer' => 'https://identity.example.test', 'subject' => 'reader'}.freeze
  BUILD = {'kind' => 'workload', 'issuer' => 'https://forge.example.test/api/actions', 'subject' => '42'}.freeze
  def release(tags = ['v1.0.0'], hex = 'a')
    {'tags' => tags, 'digest' => "sha256:#{hex * 64}", 'platforms' => [{'os' => 'linux', 'architecture' => 'arm64', 'variant' => 'v8'}]}
  end
  def store
    @store ||= ReleaseMirror::Store.new(':memory:', bootstrap: ADMIN)
  end
  def grant(person, actions, scope = 'widget')
    store.grant(ADMIN, {'identity' => person, 'scope' => scope, 'actions' => actions})
  end
end
