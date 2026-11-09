require 'jwt'
require 'net/http'
require 'uri'
require 'openssl'
require 'thread'
require_relative 'validation'

module ReleaseMirror
  class Auth
    def initialize(config, transport: Auth.method(:http_json))
      @config = config
      @transport = transport
      @keys = {}
      @mutex = Mutex.new
    end

    def self.http_json(url, form: nil, credentials: nil)
      uri = URI(url)
      raise Error.new('Authentication unavailable', 503) unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.fragment
      request = form ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request.basic_auth(*credentials) if credentials
      request.set_form_data(form) if form
      body = +''
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 5, write_timeout: 5) do |http|
        http.request(request) do |response|
          raise Error.new('Authentication unavailable', 503) unless response.code == '200'
          response.read_body do |chunk|
            body << chunk
            raise Error.new('Authentication unavailable', 503) if body.bytesize > 262_144
          end
        end
      end
      JSON.parse(body, max_nesting: 16)
    rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error.new('Authentication unavailable', 503)
    end

    def authenticate(token)
      deny unless token.is_a?(String) && token.bytesize.between?(1, 16384) && /\A[A-Za-z0-9._~+\/-]+=*\z/.match?(token)
      if token.count('.') == 2
        payload, = JWT.decode(token, nil, false)
        trusted = Array(@config['workloadIssuers']).find { |issuer| issuer['issuer'] == payload['iss'] }
        return workload(token, trusted) if trusted
      end
      human(token)
    rescue JWT::DecodeError, ArgumentError, KeyError, TypeError
      deny
    end

    def workload(token, trusted)
      payload, header = JWT.decode(token, nil, true,
        algorithms: trusted.fetch('algorithms', ['RS256']),
        jwks: keys(trusted), iss: trusted.fetch('issuer'), verify_iss: true,
        aud: trusted.fetch('audience'), verify_aud: true, verify_iat: true,
        required_claims: %w[iss aud exp iat sub])
      deny unless header['typ'] == trusted.fetch('tokenType', 'JWT')
      now = Time.now.to_i
      deny unless payload['iat'].is_a?(Numeric) && payload['exp'].is_a?(Numeric) && payload['iat'] <= now && payload['exp'] > now && payload['exp'] > payload['iat'] && payload['exp'] - payload['iat'] <= trusted.fetch('maxLifetime', 3600)
      Validation.string(payload['sub'], /\A[^\x00-\x20\x7f]{1,1024}\z/, 1024)
      repository = payload.fetch(trusted.fetch('repositoryClaim', 'repository_id'))
      deny unless repository.is_a?(String) || repository.is_a?(Integer)
      Validation.identity({'kind' => 'workload', 'issuer' => trusted['issuer'], 'subject' => repository.to_s})
    rescue JWT::DecodeError, ArgumentError, KeyError, TypeError, Error => error
      raise error if error.is_a?(Error) && error.status == 503
      deny
    end

    def keys(trusted)
      @mutex.synchronize do
        entry = @keys[trusted['issuer']]
        return entry[:value] if entry && Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry[:at] < 60
        value = @transport.call(trusted.fetch('jwksUri'))
        raise Error.new('Authentication unavailable', 503) unless value.is_a?(Hash) && value['keys'].is_a?(Array) && value['keys'].size.between?(1, 32)
        @keys[trusted['issuer']] = {value: value, at: Process.clock_gettime(Process::CLOCK_MONOTONIC)}
        value
      end
    end

    def human(token)
      provider = @config['humanApi']
      deny unless provider
      result = @transport.call(provider.fetch('introspectionUri'), form: {'token' => token, 'token_type_hint' => 'access_token'}, credentials: [provider.fetch('clientId'), ENV.fetch(provider.fetch('clientSecretEnv'))])
      deny unless result.is_a?(Hash) && result['active'] == true && result['token_type'].to_s.downcase == 'bearer'
      deny unless result['iss'] == provider['issuer'] && Array(result['aud']).include?(provider['audience'])
      now = Time.now.to_i
      deny unless result['exp'].is_a?(Numeric) && result['exp'] > now
      deny if result.key?('nbf') && (!result['nbf'].is_a?(Numeric) || result['nbf'] > now)
      deny if result.key?('iat') && (!result['iat'].is_a?(Numeric) || result['iat'] > now)
      Validation.identity({'kind' => 'human', 'issuer' => provider['issuer'], 'subject' => result['sub']})
    rescue Error => error
      raise error if error.status == 503
      deny
    rescue KeyError, TypeError
      deny
    end

    def deny = raise(Error.new('Invalid credential', 401))
  end
end
