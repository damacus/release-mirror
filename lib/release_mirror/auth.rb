# typed: true
require 'jwt'
require 'net/http'
require 'uri'
require 'openssl'
require 'thread'
require_relative 'validation'

module ReleaseMirror
  class Auth
    extend T::Sig

    class WorkloadIssuer < T::Struct
      const :issuer, String
      const :audience, String
      const :jwks_uri, String
      const :algorithms, T::Array[String]
      const :token_type, String
      const :repository_claim, String
      const :max_lifetime, Integer
    end

    class HumanProvider < T::Struct
      const :issuer, String
      const :audience, String
      const :introspection_uri, String
      const :client_id, String
      const :client_secret_env, String
    end

    class CachedKeys < T::Struct
      const :value, T::Hash[T.anything, T.anything]
      const :at, Numeric
    end

    sig { params(config: T::Hash[String, T.untyped], transport: T.untyped).void }
    def initialize(config, transport: Auth.method(:http_json))
      @workload_issuers = T.let(Array(config['workloadIssuers']).map do |issuer|
        WorkloadIssuer.new(issuer: issuer.fetch('issuer'), audience: issuer.fetch('audience'), jwks_uri: issuer.fetch('jwksUri'),
          algorithms: issuer.fetch('algorithms', ['RS256']), token_type: issuer.fetch('tokenType', 'JWT'),
          repository_claim: issuer.fetch('repositoryClaim', 'repository_id'), max_lifetime: issuer.fetch('maxLifetime', 3600))
      end, T::Array[WorkloadIssuer])
      api = config['humanApi']
      @human_api = T.let(api ? HumanProvider.new(issuer: api.fetch('issuer'), audience: api.fetch('audience'),
        introspection_uri: api.fetch('introspectionUri'), client_id: api.fetch('clientId'), client_secret_env: api.fetch('clientSecretEnv')) : nil, T.nilable(HumanProvider))
      @transport = transport
      @keys = T.let({}, T::Hash[String, CachedKeys])
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

    sig { params(token: T.anything).returns(T::Hash[String, String]) }
    def authenticate(token)
      deny unless String === token
      deny unless token.bytesize.between?(1, 16384) && /\A[A-Za-z0-9._~+\/-]+=*\z/.match?(token)
      if token.count('.') == 2
        payload, = JWT.decode(token, nil, false)
        trusted = @workload_issuers.find { |issuer| issuer.issuer == payload['iss'] }
        return workload(token, trusted) if trusted
      end
      human(token)
    rescue JWT::DecodeError, ArgumentError, KeyError, TypeError
      deny
    end

    sig { params(token: String, trusted: WorkloadIssuer).returns(T::Hash[String, String]) }
    def workload(token, trusted)
      payload, header = JWT.decode(token, nil, true,
        algorithms: trusted.algorithms,
        jwks: keys(trusted), iss: trusted.issuer, verify_iss: true,
        aud: trusted.audience, verify_aud: true, verify_iat: true,
        required_claims: %w[iss aud exp iat sub])
      deny unless header['typ'] == trusted.token_type
      now = Time.now.to_i
      deny unless payload['iat'].is_a?(Numeric) && payload['exp'].is_a?(Numeric) && payload['iat'] <= now && payload['exp'] > now && payload['exp'] > payload['iat'] && payload['exp'] - payload['iat'] <= trusted.max_lifetime
      Validation.string(payload['sub'], /\A[^\x00-\x20\x7f]{1,1024}\z/, 1024)
      repository = payload.fetch(trusted.repository_claim)
      deny unless repository.is_a?(String) || repository.is_a?(Integer)
      Validation.identity({'kind' => 'workload', 'issuer' => trusted.issuer, 'subject' => repository.to_s})
    rescue JWT::DecodeError, ArgumentError, KeyError, TypeError, Error => error
      raise error if error.is_a?(Error) && error.status == 503
      deny
    end

    sig { params(trusted: WorkloadIssuer).returns(T::Hash[T.anything, T.anything]) }
    def keys(trusted)
      @mutex.synchronize do
        entry = @keys[trusted.issuer]
        return entry.value if entry && Process.clock_gettime(Process::CLOCK_MONOTONIC) - entry.at < 60
        value = @transport.call(trusted.jwks_uri)
        raise Error.new('Authentication unavailable', 503) unless value.is_a?(Hash) && value['keys'].is_a?(Array) && value['keys'].size.between?(1, 32)
        keys = T.cast(value, T::Hash[T.anything, T.anything])
        @keys[trusted.issuer] = CachedKeys.new(value: keys, at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        keys
      end
    end

    sig { params(token: String).returns(T::Hash[String, String]) }
    def human(token)
      provider = @human_api
      deny unless provider
      result = @transport.call(provider.introspection_uri, form: {'token' => token, 'token_type_hint' => 'access_token'}, credentials: [provider.client_id, ENV.fetch(provider.client_secret_env)])
      deny unless result.is_a?(Hash) && result['active'] == true && result['token_type'].to_s.downcase == 'bearer'
      deny unless result['iss'] == provider.issuer && Array(result['aud']).include?(provider.audience)
      now = Time.now.to_i
      deny unless result['exp'].is_a?(Numeric) && result['exp'] > now
      deny if result.key?('nbf') && (!result['nbf'].is_a?(Numeric) || result['nbf'] > now)
      deny if result.key?('iat') && (!result['iat'].is_a?(Numeric) || result['iat'] > now)
      Validation.identity({'kind' => 'human', 'issuer' => provider.issuer, 'subject' => result['sub']})
    rescue Error => error
      raise error if error.status == 503
      deny
    rescue KeyError, TypeError
      deny
    end

    sig { returns(T.noreturn) }
    def deny = raise(Error.new('Invalid credential', 401))
  end
end
