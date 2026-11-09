require_relative 'test_helper'

class HttpTest < Minitest::Test
  include Rack::Test::Methods
  include Fixtures
  def config
    {'publicUrl' => 'https://catalogue.example.test', 'sessionSecretEnv' => 'TEST_SESSION_SECRET', 'bootstrap' => ADMIN}
  end
  def app
    @app ||= ReleaseMirror::App.assemble(config, catalogue: store, authenticator: Object.new.tap do |auth|
      auth.define_singleton_method(:authenticate) do |token|
        {'admin-fixture' => Fixtures::ADMIN, 'reader-fixture' => Fixtures::HUMAN, 'build-fixture' => Fixtures::BUILD}.fetch(token) { raise ReleaseMirror::Error.new('Invalid credential', 401) }
      end
    end)
  end
  def setup
    header 'Host', 'catalogue.example.test'
    store.create_service(ADMIN, 'widget')
  end
  def teardown = store.db.disconnect
  def body = JSON.parse(last_response.body)
  def api_post(path, data, token = 'admin-fixture')
    header 'Authorization', token ? "Bearer #{token}" : nil
    post path, JSON.generate(data), {'CONTENT_TYPE' => 'application/json'}
  end

  def test_catalogue_http_contract
    get '/api/v1/services'
    assert_equal 200, last_response.status
    assert_equal({'services' => ['widget']}, body)
    assert_equal 'public, max-age=0, must-revalidate', last_response['cache-control']
    assert_nil last_response['set-cookie']
    api_post '/api/v1/services/widget/releases', release
    assert_equal 200, last_response.status
    assert_equal %w[digest platforms publishedAt service updatedAt version], body['releases'][0].keys.sort
    get '/api/v1/services/widget/releases/v1.0.0'
    assert_equal 'v1.0.0', body.fetch('version')
    header 'Authorization', nil
    get '/api/v1/services/widget/renovate'
    assert_equal release['digest'], body['releases'][0]['digest']
    assert_equal 'v1.0.0', body['releases'][0]['version']
    header 'Authorization', 'Bearer admin-fixture'
    delete '/api/v1/services/widget/releases/v1.0.0'
    assert_equal 204, last_response.status
    get '/api/v1/services/widget/releases/v1.0.0'
    assert_equal 404, last_response.status
    get '/api/v1/services/widget/releases'
    assert_empty body['releases']
  end

  def test_read_only_and_anonymous_cannot_mutate
    [nil, 'reader-fixture'].each do |token|
      api_post '/api/v1/services/widget/releases', release, token
      assert_equal token ? 403 : 401, last_response.status
    end
    api_post '/api/v1/services', {'name' => 'other'}, 'build-fixture'
    assert_equal 403, last_response.status
  end

  def test_rejected_input_is_not_echoed_or_logged
    errors = StringIO.new
    header 'Authorization', 'Bearer admin-fixture'
    post '/api/v1/services/widget/releases', JSON.generate(release.merge('secret' => 'SENSITIVE')), {'CONTENT_TYPE' => 'application/json', 'rack.errors' => errors}
    assert_equal 422, last_response.status
    refute_includes last_response.body, 'SENSITIVE'
    assert_empty errors.string
    post '/api/v1/services/widget/releases', '{broken SENSITIVE', {'CONTENT_TYPE' => 'application/json', 'rack.errors' => errors}
    assert_equal 400, last_response.status
    refute_includes last_response.body, 'SENSITIVE'
    assert_empty errors.string
  end

  def test_request_bounds_host_and_content_type
    api_post '/api/v1/services/widget/releases', release.merge('secret' => 'x' * 1_048_576)
    assert_equal 413, last_response.status
    post '/api/v1/services/widget/releases', 'plain', {'CONTENT_TYPE' => 'text/plain'}
    assert_equal 415, last_response.status
    header 'Host', 'evil.example.test'
    get '/api/v1/services'
    assert_equal 403, last_response.status
    header 'Forwarded', 'host=catalogue.example.test;proto=https'
    get '/api/v1/services'
    assert_equal 403, last_response.status
    header 'Forwarded', nil
    header 'X-Forwarded-Host', 'catalogue.example.test'
    get '/api/v1/services'
    assert_equal 403, last_response.status
  end

  def test_health_and_static_css_need_no_session
    get '/health'
    assert_equal 200, last_response.status
    assert_equal({'status' => 'ok'}, body)
    assert_nil last_response['set-cookie']
    get '/catalogue.css'
    assert_equal 200, last_response.status
    assert_nil last_response['set-cookie']
  end

  def test_callback_without_verified_login_is_denied
    get '/auth/oidc/callback'
    assert_equal 401, last_response.status
  end

  def test_dashboard_public_values_and_csrf
    store.publish(ADMIN, 'widget', release)
    get '/'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Container releases'
    get '/services/widget'
    assert_equal 200, last_response.status
    assert_includes last_response.body, release['digest']
    refute_includes last_response.body, 'Publish metadata ↗'
    assert_includes last_response['content-security-policy'], "frame-ancestors 'none'"
    post '/services', {'name' => 'forged'}
    assert_equal 403, last_response.status
  end

  def test_import_is_atomic_and_export_contains_no_grants
    api_post '/api/v1/services/widget/releases', release
    get '/api/v1/export'
    snapshot = body
    refute_includes snapshot.to_json, 'operator'
    snapshot['services'] << {'name' => 'bad', 'releases' => [{'unexpected' => 'value'}]}
    api_post '/api/v1/import', snapshot
    assert_equal 422, last_response.status
    refute store.exists?('bad')
  end

  def test_import_rejects_invalid_calendar_date_and_rolls_back
    store.publish(ADMIN, 'widget', release)
    original = store.export
    invalid = Marshal.load(Marshal.dump(original))
    invalid['services'][0]['releases'][0]['publishedAt'] = '2026-99-01T00:00:00Z'
    api_post '/api/v1/import', invalid
    assert_equal 422, last_response.status
    assert_equal 'Invalid request', body['error']
    assert_equal original, store.export
  end

  def test_rejects_invalid_authorization_and_request_boundaries
    header 'Authorization', 'Basic secret'
    get '/api/v1/grants'
    assert_equal 401, last_response.status
    header 'Authorization', 'Bearer too many parts'
    get '/api/v1/grants'
    assert_equal 401, last_response.status
    header 'Authorization', nil
    get "/api/v1/services?#{'q' * 4097}"
    assert_equal 400, last_response.status
    get '/' + ('a' * 2049)
    assert_equal 400, last_response.status
    post '/services', JSON.generate(name: 'x'), {'CONTENT_TYPE' => 'application/json'}
    assert_equal 403, last_response.status
    boundary = ReleaseMirror::Boundary.new(->(_env) { [200, {}, []] }, config)
    env = Rack::MockRequest.env_for('https://catalogue.example.test/services', method: 'POST', input: 'csrf=valid', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded', 'HTTP_ORIGIN' => 'https://evil.example.test')
    env['HTTP_HOST'] = 'catalogue.example.test'
    env['rack.session'] = {'csrf' => 'valid'}
    assert_equal 403, boundary.call(env).first
  end

  def test_admin_can_grant_and_revoke_publisher_through_api
    api_post '/api/v1/grants', {'identity' => BUILD, 'scope' => 'widget', 'actions' => ['publish']}
    assert_equal 204, last_response.status
    header 'Authorization', 'Bearer admin-fixture'
    get '/api/v1/grants', {'scope' => 'widget'}
    assert_equal 200, last_response.status
    grant_id = body.fetch('grants').first.fetch('id')
    api_post '/api/v1/services/widget/releases', release, 'build-fixture'
    assert_equal 200, last_response.status
    header 'Authorization', 'Bearer admin-fixture'
    delete '/api/v1/grants/invalid'
    assert_equal 422, last_response.status
    delete "/api/v1/grants/#{grant_id}"
    assert_equal 204, last_response.status
    api_post '/api/v1/services/widget/releases', release(['new-tag']), 'build-fixture'
    assert_equal 403, last_response.status
  end

  def test_assembly_requires_a_long_session_secret
    ENV['SHORT_TEST_SESSION_SECRET'] = 'short'
    error = assert_raises(ReleaseMirror::Error) { ReleaseMirror::App.assemble(config.merge('sessionSecretEnv' => 'SHORT_TEST_SESSION_SECRET'), catalogue: store) }
    assert_equal 500, error.status
  ensure
    ENV.delete('SHORT_TEST_SESSION_SECRET')
  end

  def test_local_fixture_origin_uses_fixture_content_security_policy
    boundary = ReleaseMirror::Boundary.new(->(_env) { [200, {}, []] }, config.merge('publicUrl' => 'http://localhost:9292'))
    env = Rack::MockRequest.env_for('http://localhost:9292/health')
    env['HTTP_HOST'] = 'localhost:9292'
    status, headers, = boundary.call(env)
    assert_equal 200, status
    assert_includes headers.fetch('content-security-policy'), "form-action 'self' http: https:"
  end
end
