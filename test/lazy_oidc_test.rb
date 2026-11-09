require_relative 'test_helper'
require 'open3'
require 'rbconfig'

class LazyOidcTest < Minitest::Test
  def test_public_reads_do_not_load_configured_browser_login
    program = <<~'RUBY'
      require_relative 'lib/release_mirror/app'
      ENV['LAZY_SESSION_SECRET'] = 's' * 96
      ENV['LAZY_CLIENT_SECRET'] = 'fixture'
      config = {'publicUrl' => 'http://localhost:9292', 'sessionSecretEnv' => 'LAZY_SESSION_SECRET',
                'browserOidc' => {'issuer' => 'https://identity.example.test', 'clientId' => 'fixture', 'clientSecretEnv' => 'LAZY_CLIENT_SECRET'}}
      store = ReleaseMirror::Store.new(':memory:')
      app = ReleaseMirror::App.assemble(config, catalogue: store)
      request = Rack::MockRequest.new(app)
      %w[/ /health /api/v1/services].each do |path|
        response = request.get(path, 'HTTP_HOST' => 'localhost:9292')
        abort "Unexpected status for #{path}" unless response.status == 200
      end
      abort 'OIDC was loaded before login' if $LOADED_FEATURES.any? { |path| path.include?('omniauth_oidc') }
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, '-rbundler/setup', '-e', program)
    assert status.success?, "#{output}\n#{error}"
  end
end
