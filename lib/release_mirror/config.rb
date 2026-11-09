# typed: true
require 'json'
require 'uri'
require_relative 'validation'

module ReleaseMirror
  module Config
    include Kernel
    extend T::Sig
    module_function
    sig { returns(T::Hash[String, T.untyped]) }
    def load
      config = JSON.parse(File.read(ENV.fetch('CONFIG_FILE', 'config/local.json')), max_nesting: 16)
      validate(config)
      config
    rescue Errno::ENOENT
      raise Error.new('Configure CONFIG_FILE before starting', 500)
    end

    sig { params(value: T.anything).void }
    def https(value)
      raise Error unless String === value || URI::Generic === value
      uri = URI(value)
      raise Error unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
    rescue URI::InvalidURIError, TypeError
      raise Error
    end

    sig { params(config: T.untyped).returns(T::Hash[String, T.untyped]) }
    def validate(config)
      Validation.object(config, %w[publicUrl databasePath bootstrap workloadIssuers humanApi browserOidc sessionSecretEnv], %w[publicUrl sessionSecretEnv])
      https(config['publicUrl']) unless config['publicUrl'] == 'http://localhost:9292'
      Validation.identity(config['bootstrap']) if config['bootstrap']
      raise Error if config['bootstrap'] && config['bootstrap']['kind'] != 'human'
      issuers = config.fetch('workloadIssuers', [])
      raise Error unless issuers.is_a?(Array) && issuers.size <= 16
      raise Error unless issuers.map { |x| x['issuer'] }.uniq.size == issuers.size
      issuers.each do |provider|
        Validation.object(provider, %w[issuer audience jwksUri algorithms tokenType repositoryClaim maxLifetime], %w[issuer audience jwksUri])
        %w[issuer jwksUri].each { |key| https(provider[key]) }
        raise Error unless (provider.fetch('algorithms', ['RS256']) - %w[RS256 RS384 RS512 ES256 ES384 ES512]).empty? && !provider.fetch('algorithms', ['RS256']).empty?
        Validation.string(provider['audience'], /\A\S{1,256}\z/, 256)
        raise Error unless provider.fetch('maxLifetime', 3600).is_a?(Integer) && provider.fetch('maxLifetime', 3600).between?(1, 86400)
      end
      if (api = config['humanApi'])
        Validation.object(api, %w[issuer audience introspectionUri clientId clientSecretEnv], %w[issuer audience introspectionUri clientId clientSecretEnv])
        %w[issuer introspectionUri].each { |key| https(api[key]) }
      end
      if (browser = config['browserOidc'])
        Validation.object(browser, %w[issuer clientId clientSecretEnv signingAlgorithm], %w[issuer clientId clientSecretEnv])
        https(browser['issuer'])
        raise Error unless %w[RS256 RS384 RS512 ES256 ES384 ES512].include?(browser.fetch('signingAlgorithm', 'RS256'))
      end
      config
    end
  end
end
