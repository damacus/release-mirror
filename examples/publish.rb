#!/usr/bin/env ruby
# Run after a successful image push. No token or raw payload is printed.
# This publisher needs only Ruby's standard library.
require 'net/http'
require 'json'
require 'uri'

begin
  base = URI(ENV.fetch('CATALOGUE_URL'))
  raise unless base.is_a?(URI::HTTPS) && base.host && !base.userinfo && !base.query && !base.fragment
  service = ENV.fetch('CATALOGUE_SERVICE')
  raise unless /\A[a-z0-9][a-z0-9_-]{0,63}\z/.match?(service)
  audience = ENV.fetch('CATALOGUE_AUDIENCE')
  payload_file = ENV['CATALOGUE_PAYLOAD_FILE']
  payload = if payload_file && !payload_file.empty?
    File.binread(payload_file, 1_048_577)
  else
    JSON.generate(
      'tags' => ENV.fetch('CATALOGUE_TAGS').lines.map(&:chomp).reject(&:empty?),
      'digest' => ENV.fetch('CATALOGUE_DIGEST'),
      'platforms' => JSON.parse(ENV.fetch('CATALOGUE_PLATFORMS')),
      'immutable' => JSON.parse(ENV.fetch('CATALOGUE_IMMUTABLE', 'false'))
    )
  end
  raise if payload.bytesize > 1_048_576
  token_url = URI(ENV.fetch('ACTIONS_ID_TOKEN_REQUEST_URL'))
  raise unless token_url.is_a?(URI::HTTPS) && !token_url.userinfo && !token_url.fragment
  query = URI.decode_www_form(token_url.query.to_s).reject { |key, _| key == 'audience' }
  token_url.query = URI.encode_www_form(query + [['audience', audience]])
  token_request = Net::HTTP::Get.new(token_url)
  token_request['Authorization'] = "Bearer #{ENV.fetch('ACTIONS_ID_TOKEN_REQUEST_TOKEN')}"
  response = Net::HTTP.start(token_url.host, token_url.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http| http.request(token_request) }
  raise unless response.code == '200' && response.body.bytesize <= 32768
  token = JSON.parse(response.body).fetch('value')
  target = URI("#{base.to_s.delete_suffix('/')}/api/v1/services/#{service}/releases")
  request = Net::HTTP::Post.new(target)
  request['Authorization'] = "Bearer #{token}"
  request['Content-Type'] = 'application/json'
  request.body = payload
  result = Net::HTTP.start(target.host, target.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
  raise unless result.code == '200'
  puts 'Published public release metadata.'
rescue StandardError
  warn 'Publication failed. Check issuer configuration, service grants and the metadata allowlist. No input or credential has been printed.'
  exit 1
end
