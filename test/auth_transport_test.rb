require_relative 'test_helper'
require 'webmock/minitest'

class AuthTransportTest < Minitest::Test
  URL = 'https://identity.example.test/token'

  def test_fetches_json_and_posts_introspection_with_basic_auth
    stub_request(:get, URL).to_return(status: 200, body: '{"keys":[{"kid":"fixture"}]}')
    assert_equal({'keys' => [{'kid' => 'fixture'}]}, ReleaseMirror::Auth.http_json(URL))

    form = {'token' => 'fixture-token', 'token_type_hint' => 'access_token'}
    stub_request(:post, URL).with(basic_auth: ['fixture-client', 'fixture-secret'], body: form)
      .to_return(status: 200, body: '{"active":true}')
    assert_equal({'active' => true}, ReleaseMirror::Auth.http_json(URL, form: form, credentials: ['fixture-client', 'fixture-secret']))
    assert_requested(:post, URL, body: form, basic_auth: ['fixture-client', 'fixture-secret'])
  end

  def test_provider_errors_are_generic
    [{status: 401, body: 'fixture-sensitive'}, {status: 200, body: '{fixture-sensitive'}, {status: 200, body: JSON.generate('x' * 262_144)}].each do |response|
      stub_request(:get, URL).to_return(response)
      error = assert_raises(ReleaseMirror::Error) { ReleaseMirror::Auth.http_json(URL) }
      assert_equal 503, error.status
      assert_equal 'Authentication unavailable', error.message
    end
    stub_request(:get, URL).to_timeout
    assert_equal 503, assert_raises(ReleaseMirror::Error) { ReleaseMirror::Auth.http_json(URL) }.status
  end

  def test_rejects_insecure_identity_endpoint
    ['http://identity.example.test/token', 'https://user:password@identity.example.test/token', 'https://identity.example.test/token#fragment'].each do |url|
      assert_equal 503, assert_raises(ReleaseMirror::Error) { ReleaseMirror::Auth.http_json(url) }.status
    end
  end
end
