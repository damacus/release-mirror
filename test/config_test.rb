require_relative 'test_helper'

class ConfigTest < Minitest::Test
  def base
    {'publicUrl' => 'https://catalogue.example.test', 'sessionSecretEnv' => 'TEST_SESSION_SECRET'}
  end

  def workload
    {'issuer' => 'https://forge.example.test/api/actions', 'audience' => 'catalogue', 'jwksUri' => 'https://forge.example.test/keys'}
  end

  def test_valid_identity_providers_and_local_fixture_origin
    config = base.merge('bootstrap' => Fixtures::ADMIN, 'workloadIssuers' => [workload],
      'browserOidc' => {'issuer' => 'https://identity.example.test', 'clientId' => 'browser', 'clientSecretEnv' => 'BROWSER_SECRET'},
      'humanApi' => {'issuer' => 'https://identity.example.test', 'audience' => 'catalogue', 'introspectionUri' => 'https://identity.example.test/introspect', 'clientId' => 'api', 'clientSecretEnv' => 'API_SECRET'})
    assert_same config, ReleaseMirror::Config.validate(config)
    assert_equal 'http://localhost:9292', ReleaseMirror::Config.validate(base.merge('publicUrl' => 'http://localhost:9292'))['publicUrl']
  end

  def test_rejects_unsafe_public_and_identity_urls
    ['http://catalogue.example.test', 'https://user:password@catalogue.example.test', 'https://catalogue.example.test/?secret=1', 'https://catalogue.example.test/#fragment', nil].each do |url|
      assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('publicUrl' => url)) }
    end
    ['http://forge.example.test/keys', 'https://user@forge.example.test/keys', 'https://forge.example.test/keys?secret=1'].each do |url|
      assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('workloadIssuers' => [workload.merge('jwksUri' => url)])) }
    end
  end

  def test_rejects_invalid_workload_trust_configuration
    invalid_issuers = [
      [workload, workload],
      [workload.merge('algorithms' => [])],
      [workload.merge('algorithms' => ['HS256'])],
      [workload.merge('maxLifetime' => 0)],
      [workload.merge('maxLifetime' => 86_401)],
      [workload.merge('audience' => '')]
    ]
    invalid_issuers.each { |issuers| assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('workloadIssuers' => issuers)) } }
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('workloadIssuers' => 'invalid')) }
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('workloadIssuers' => Array.new(17) { workload })) }
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('bootstrap' => Fixtures::BUILD)) }
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Config.validate(base.merge('browserOidc' => {'issuer' => 'https://id.example.test', 'clientId' => 'client', 'clientSecretEnv' => 'SECRET', 'signingAlgorithm' => 'none'})) }
  end
end
