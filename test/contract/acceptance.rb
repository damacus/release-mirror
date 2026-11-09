# Standalone HTTP contract: no application imports. Requires an isolated catalogue
# and a global administrator API token in CONTRACT_TOKEN_FILE. Never run on live data.
require 'net/http'
require 'json'
require 'uri'

base = ENV.fetch('CONTRACT_URL', 'http://localhost:9292')
token = File.read(ENV.fetch('CONTRACT_TOKEN_FILE')).strip
digest_a = "sha256:#{'a' * 64}"
digest_b = "sha256:#{'b' * 64}"
service = 'contract-fixture'
platforms = [{'os' => 'linux', 'architecture' => 'amd64'}]
request = lambda do |method, path, body = nil, authenticated = false|
  uri = URI("#{base}#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req['Authorization'] = "Bearer #{token}" if authenticated
  if body
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(body)
  end
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 5) { |http| http.request(req) }
end
assert = ->(condition, description) { raise "Contract failure: #{description}" unless condition }
path = "/api/v1/services/#{service}"
begin
  created = request.call('post', '/api/v1/services', {'name' => service}, true)
  assert.call(created.code == '201', 'isolated alias creation')
  data = {'tags' => ['v1.0.0', 'actual-moving-tag'], 'digest' => digest_a, 'platforms' => platforms}
  denied = request.call('post', "#{path}/releases", data)
  assert.call(denied.code == '401', 'anonymous write rejection')
  published = request.call('post', "#{path}/releases", data, true)
  assert.call(published.code == '200', 'authenticated publication')
  rows = JSON.parse(published.body).fetch('releases')
  assert.call(rows.map { |row| row['version'] }.sort == data['tags'].sort, 'exact tags')
  assert.call(rows.all? { |row| row.keys.sort == %w[digest platforms publishedAt service updatedAt version] }, 'public allowlist')
  read = request.call('get', "#{path}/releases")
  assert.call(read['cache-control'] == 'public, max-age=0, must-revalidate', 'cache revalidation')
  assert.call(read['set-cookie'].nil?, 'public JSON must never issue session cookies')
  changed = request.call('post', "#{path}/releases", data.merge('digest' => digest_b), true)
  assert.call(JSON.parse(changed.body)['releases'].all? { |row| row['digest'] == digest_b }, 'moving digest')
  rejected = request.call('post', "#{path}/releases", data.merge('source' => 'never-public'), true)
  assert.call(rejected.code == '422' && !rejected.body.include?('never-public'), 'unexpected metadata rejection')
  feed = JSON.parse(request.call('get', "#{path}/renovate").body)
  assert.call(feed['releases'].all? { |row| row['digest'] == digest_b && row['releaseTimestamp'] }, 'Renovate shape')
  removed = request.call('delete', "#{path}/releases/v1.0.0", nil, true)
  assert.call(removed.code == '204', 'complete deletion')
  assert.call(request.call('get', "#{path}/releases/v1.0.0").code == '404', 'no tombstone')
  snapshot = JSON.parse(request.call('get', '/api/v1/export').body)
  assert.call(snapshot['schemaVersion'] == 1, 'portable format')
  puts 'HTTP contract passed: exact tags, digest updates, allowlist, permissions, deletion, cache and export.'
ensure
  request.call('delete', path, nil, true) if created&.code == '201'
end
