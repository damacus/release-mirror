require_relative 'test_helper'

class AuthTest < Minitest::Test
  include Fixtures
  KEY = OpenSSL::PKey::RSA.generate(2048)
  OTHER_KEY = OpenSSL::PKey::RSA.generate(2048)
  def setup
    @issuer = {'issuer' => BUILD['issuer'], 'audience' => 'catalogue', 'jwksUri' => 'https://forge.example.test/keys'}
    @claims = {'iss' => BUILD['issuer'], 'sub' => 'repo:example/widget:pull_request', 'repository_id' => 42, 'aud' => 'catalogue', 'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 600, 'event_name' => 'pull_request'}
    @calls = []
    @auth = ReleaseMirror::Auth.new({'workloadIssuers' => [@issuer]}, transport: ->(url) { @calls << url; {'keys' => [JWT::JWK.new(KEY.public_key).export]} })
  end
  def token(claims = @claims, key = KEY, headers = {}) = JWT.encode(claims, key, 'RS256', {'typ' => 'JWT', 'kid' => JWT::JWK.new(key.public_key).kid, **headers})

  def test_signed_pr_build_identity_and_keys_cache
    assert_equal BUILD, @auth.authenticate(token)
    assert_equal BUILD, @auth.authenticate(token(@claims.merge('event_name' => 'push', 'ref' => 'refs/heads/arbitrary')))
    assert_equal [@issuer['jwksUri']], @calls
  end

  def test_signature_issuer_audience_time_type_and_identity
    mutations = [{'aud' => 'wrong'}, {'iss' => 'https://evil.example.test'}, {'exp' => Time.now.to_i - 1}, {'iat' => Time.now.to_i + 30}, {'nbf' => Time.now.to_i + 30}, {'exp' => Time.now.to_i + 90000}, {'repository_id' => {}}, {'sub' => ''}]
    mutations.each do |change|
      assert_equal 401, assert_raises(ReleaseMirror::Error) { @auth.authenticate(token(@claims.merge(change))) }.status
    end
    assert_raises(ReleaseMirror::Error) { @auth.authenticate(token(@claims, OTHER_KEY)) }
    assert_raises(ReleaseMirror::Error) { @auth.authenticate(token(@claims, KEY, {'typ' => 'at+jwt'})) }
    assert_raises(ReleaseMirror::Error) { @auth.authenticate(JWT.encode(@claims, nil, 'none')) }
    assert_raises(ReleaseMirror::Error) { @auth.authenticate(token(@claims.reject { |k, _| k == 'exp' })) }
  end

  def test_header_key_url_is_ignored
    assert_equal BUILD, @auth.authenticate(token(@claims, KEY, {'jku' => 'https://evil.example.test/keys'}))
    assert_equal [@issuer['jwksUri']], @calls
  end

  def test_human_opaque_and_jwt_access_tokens_use_introspection
    ENV['TEST_API_SECRET'] = 'test-only'
    api = {'issuer' => HUMAN['issuer'], 'audience' => 'catalogue', 'introspectionUri' => 'https://identity.example.test/introspect', 'clientId' => 'api', 'clientSecretEnv' => 'TEST_API_SECRET'}
    result = {'active' => true, 'token_type' => 'Bearer', 'iss' => HUMAN['issuer'], 'aud' => ['catalogue'], 'exp' => Time.now.to_i + 60, 'sub' => HUMAN['subject']}
    transport = lambda do |url, form:, credentials:|
      assert_equal api['introspectionUri'], url
      assert_equal 'access_token', form['token_type_hint']
      assert_equal ['api', 'test-only'], credentials
      result
    end
    auth = ReleaseMirror::Auth.new({'humanApi' => api}, transport: transport)
    assert_equal HUMAN, auth.authenticate('opaque-access-token')
    assert_equal HUMAN, auth.authenticate(token(@claims.merge('iss' => HUMAN['issuer'])))
    [{'active' => false}, {'token_type' => 'id_token'}, {'aud' => ['other']}, {'iss' => 'https://other.example.test'}, {'exp' => 1}, {'sub' => nil}].each do |change|
      saved = result.dup
      result.merge!(change)
      assert_raises(ReleaseMirror::Error) { auth.authenticate('opaque') }
      result.replace(saved)
    end
  ensure
    ENV.delete('TEST_API_SECRET')
  end

  def test_authentication_does_not_imply_authorisation
    store.create_service(ADMIN, 'widget')
    different = @auth.authenticate(token(@claims.merge('repository_id' => 99)))
    grant(BUILD, ['publish'])
    assert_raises(ReleaseMirror::Error) { store.publish(different, 'widget', release) }
  ensure
    store.db.disconnect
  end
end
