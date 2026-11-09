require_relative 'test_helper'
require 'webmock/minitest'
require 'base64'
require 'digest'

class BrowserTest < Minitest::Test
  include Rack::Test::Methods
  include Fixtures
  KEY = OpenSSL::PKey::RSA.generate(2048)
  ISSUER = 'https://identity.example.test'
  def app
    @app ||= ReleaseMirror::App.assemble({'publicUrl' => 'https://catalogue.example.test', 'sessionSecretEnv' => 'TEST_SESSION_SECRET', 'bootstrap' => ADMIN,
      'browserOidc' => {'issuer' => ISSUER, 'clientId' => 'browser', 'clientSecretEnv' => 'TEST_BROWSER_SECRET'}}, catalogue: store)
  end
  def setup
    ENV['TEST_BROWSER_SECRET'] = 'fixture-client-secret'
    header 'Host', 'catalogue.example.test'
    stub_request(:get, "#{ISSUER}/.well-known/openid-configuration").to_return(headers: {'Content-Type' => 'application/json'}, body: JSON.generate({issuer: ISSUER, authorization_endpoint: "#{ISSUER}/authorize", token_endpoint: "#{ISSUER}/token", userinfo_endpoint: "#{ISSUER}/userinfo", jwks_uri: "#{ISSUER}/keys", response_types_supported: ['code'], subject_types_supported: ['public'], id_token_signing_alg_values_supported: ['RS256']}))
    stub_request(:get, "#{ISSUER}/keys").to_return(headers: {'Content-Type' => 'application/json'}, body: JSON.generate(keys: [JWT::JWK.new(KEY.public_key).export]))
  end
  def teardown
    store.db.disconnect
    ENV.delete('TEST_BROWSER_SECRET')
  end
  def csrf_token = last_response.body[/name="csrf" value="([^"]+)"/, 1]
  def begin_login
    get 'https://catalogue.example.test/'
    csrf = csrf_token
    post 'https://catalogue.example.test/auth/oidc', {'csrf' => csrf}
    assert_equal 302, last_response.status
    URI.decode_www_form(URI(last_response['location']).query).to_h
  end
  def provider_response(params, subject: 'operator', nonce: params['nonce'], id_token: true, claims: {}, key: KEY)
    token = JWT.encode({'iss' => ISSUER, 'sub' => subject, 'aud' => 'browser', 'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 600, 'nonce' => nonce}.merge(claims).compact, key, 'RS256', {'kid' => JWT::JWK.new(KEY.public_key).kid})
    response = {'access_token' => 'fixture-access-token', 'token_type' => 'Bearer', 'expires_in' => 600}
    response['id_token'] = token if id_token
    stub_request(:post, "#{ISSUER}/token").with do |request|
      form = URI.decode_www_form(request.body).to_h
      verifier = form['code_verifier']
      verifier && Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) == params['code_challenge']
    end.to_return(headers: {'Content-Type' => 'application/json'}, body: JSON.generate(response))
  end

  def test_login_pkce_admin_and_dashboard_journey
    auth = begin_login
    assert_equal 'S256', auth['code_challenge_method']
    assert auth['state'] && auth['nonce'] && auth['code_challenge']
    assert_equal 'https://catalogue.example.test/auth/oidc/callback', auth['redirect_uri']
    provider_response(auth)
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    assert_equal 303, last_response.status
    assert_includes last_response['set-cookie'], 'secure'
    assert_includes last_response['set-cookie'], 'httponly'
    follow_redirect!
    assert_includes last_response.body, 'Add a service'
    get 'https://catalogue.example.test/api/v1/services'
    assert_nil last_response['set-cookie']
    get 'https://catalogue.example.test/'
    token = csrf_token
    post 'https://catalogue.example.test/services', {'name' => 'widget', 'csrf' => token}
    assert_equal 303, last_response.status
    follow_redirect!
    assert_includes last_response.body, 'Publish metadata'
    token = csrf_token
    post 'https://catalogue.example.test/services/widget/releases', {'tags' => 'v1.0.0', 'digest' => release['digest'], 'platforms' => JSON.generate(release['platforms']), 'csrf' => token}
    assert_equal 303, last_response.status
    follow_redirect!
    assert_includes last_response.body, release['digest']
    token = csrf_token
    post 'https://catalogue.example.test/services/widget/releases/v1.0.0/delete', {'csrf' => token}
    assert_equal 303, last_response.status
    assert_empty store.releases('widget')
    get 'https://catalogue.example.test/permissions'
    assert_equal 200, last_response.status
    token = csrf_token
    post 'https://catalogue.example.test/permissions', {'csrf' => token, 'role' => 'admin', 'issuer' => ISSUER, 'subject' => '<script>alert(1)</script>', 'scope' => '*'}
    follow_redirect!
    assert_includes last_response.body, '&lt;script&gt;'
    refute_includes last_response.body, '<script>'
    post 'https://catalogue.example.test/logout', {'csrf' => csrf_token}
    assert_equal 303, last_response.status
    follow_redirect!
    refute_includes last_response.body, 'Add a service'
  end

  def test_invalid_signed_token_claims_and_signature_are_rejected
    [{'iss' => 'https://wrong.example.test'}, {'aud' => 'other'}, {'exp' => Time.now.to_i - 120}, {'iat' => nil}, {'aud' => ['browser', 'other']}, {'azp' => 'other'}].each do |claims|
      auth = begin_login
      provider_response(auth, claims: claims)
      get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
      assert_equal 401, last_response.status
    end
    auth = begin_login
    provider_response(auth, key: OpenSSL::PKey::RSA.generate(2048))
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    assert_equal 401, last_response.status
  end

  def test_first_login_is_read_only_and_cookie_cannot_authorise_api
    auth = begin_login
    provider_response(auth, subject: 'new-person')
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    follow_redirect!
    refute_includes last_response.body, 'Add a service'
    post 'https://catalogue.example.test/api/v1/services', JSON.generate(name: 'widget'), {'CONTENT_TYPE' => 'application/json'}
    assert_equal 401, last_response.status
  end

  def test_state_nonce_and_callback_injection_fail_closed
    auth = begin_login
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => 'wrong'}
    assert_equal 401, last_response.status
    auth = begin_login
    provider_response(auth, nonce: 'wrong')
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    assert_equal 401, last_response.status
    auth = begin_login
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state'], 'nonce' => 'caller-chosen'}
    assert_equal 401, last_response.status
  end

  def test_missing_id_token_rejected_and_callback_replay_rejected
    auth = begin_login
    provider_response(auth, id_token: false)
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    assert_equal 401, last_response.status
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    assert_equal 401, last_response.status
  end

  def test_login_and_authenticated_session_expire
    auth = begin_login
    future = Time.now + 301
    Time.stub(:now, future) do
      get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
      assert_equal 401, last_response.status
    end
    auth = begin_login
    provider_response(auth)
    get 'https://catalogue.example.test/auth/oidc/callback', {'code' => 'fixture-code', 'state' => auth['state']}
    follow_redirect!
    assert_includes last_response.body, 'Add a service'
    Time.stub(:now, Time.now + 3601) do
      get 'https://catalogue.example.test/'
      refute_includes last_response.body, 'Add a service'
    end
  end
end
