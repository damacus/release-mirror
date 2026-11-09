# Local synthetic fixture server. Never used by the production entrypoint.
require 'bundler/setup'
require 'puma'
require 'tmpdir'
require_relative '../../lib/release_mirror/app'

directory = ENV.fetch('FIXTURE_DIR')
port = Integer(ENV.fetch('FIXTURE_PORT', '9292'))
FileUtils.mkdir_p(directory, mode: 0o700)
key = OpenSSL::PKey::RSA.generate(2048)
issuer = 'https://forge.example.test/api/actions'
admin = {'kind' => 'human', 'issuer' => 'https://identity.example.test', 'subject' => 'fixture-operator'}
build = {'kind' => 'workload', 'issuer' => issuer, 'subject' => '42'}
public_url = port == 9292 ? 'http://localhost:9292' : "https://localhost:#{port}"
config = {'publicUrl' => public_url, 'databasePath' => File.join(directory, 'fixture.sqlite3'), 'sessionSecretEnv' => 'FIXTURE_SESSION_SECRET', 'bootstrap' => admin,
  'humanApi' => {'issuer' => admin['issuer'], 'audience' => 'fixture-catalogue', 'introspectionUri' => 'https://identity.example.test/introspect', 'clientId' => 'fixture', 'clientSecretEnv' => 'FIXTURE_API_SECRET'},
  'workloadIssuers' => [{'issuer' => issuer, 'audience' => 'fixture-catalogue', 'jwksUri' => 'https://forge.example.test/keys'}]}
ENV['FIXTURE_SESSION_SECRET'] = SecureRandom.hex(64)
ENV['FIXTURE_API_SECRET'] = 'fixture-only'
catalogue = ReleaseMirror::Store.new(config['databasePath'], bootstrap: admin)
catalogue.create_service(admin, 'widget') unless catalogue.exists?('widget')
catalogue.grant(admin, {'identity' => build, 'scope' => 'widget', 'actions' => ['publish']})
[['v1.0.0', 'a'], ['v1.1.0', 'b'], ['latest', 'c']].each do |tag, hex|
  catalogue.publish(admin, 'widget', {'tags' => [tag], 'digest' => "sha256:#{hex * 64}", 'platforms' => [{'os' => 'linux', 'architecture' => 'amd64'}, {'os' => 'linux', 'architecture' => 'arm64', 'variant' => 'v8'}]})
end
claims = {'iss' => issuer, 'sub' => 'repo:example/widget:pull_request', 'repository_id' => 42, 'aud' => 'fixture-catalogue', 'iat' => Time.now.to_i, 'exp' => Time.now.to_i + 3600}
File.write(File.join(directory, 'token'), 'fixture-admin-token', mode: 'w', perm: 0o600)
File.write(File.join(directory, 'publisher-token'), JWT.encode(claims, key, 'RS256', {'typ' => 'JWT', 'kid' => JWT::JWK.new(key.public_key).kid}), mode: 'w', perm: 0o600)
File.write(File.join(directory, 'config.json'), JSON.pretty_generate(config))
auth = ReleaseMirror::Auth.new(config, transport: lambda { |url, **options|
  if url == config['humanApi']['introspectionUri'] && options.dig(:form, 'token') == 'fixture-admin-token'
    {'active' => true, 'token_type' => 'Bearer', 'iss' => admin['issuer'], 'aud' => ['fixture-catalogue'], 'exp' => Time.now.to_i + 3600, 'sub' => admin['subject']}
  else
    {'keys' => [JWT::JWK.new(key.public_key).export]}
  end
})
app = ReleaseMirror::App.assemble(config, catalogue: catalogue, authenticator: auth)
server = Puma::Server.new(app, nil, {min_threads: 1, max_threads: 5})
server.add_tcp_listener('127.0.0.1', port)
trap('TERM') { server.stop }
trap('INT') { server.stop }
server.run.join
