require 'omniauth_oidc'
require 'logger'

# Provider errors can contain untrusted claims or callback parameters.
OmniauthOidc::Logging.logger = Logger.new(File::NULL)

module ReleaseMirror
  # The upstream strategy allows caller-supplied nonce/verifier overrides.
  # Browser login must use only the values in the initiating session.
  class BrowserOIDC < OmniAuth::Strategies::Oidc
    option :name, 'oidc'
    option :fixed_redirect_uri

    def call(env)
      return @app.call(env) if env['PATH_INFO'].to_s.start_with?('/api/', '/health', '/catalogue.css')
      super
    end

    def callback_phase
      started = session.delete('login_started')
      forbidden = %w[nonce code_verifier redirect_uri id_token]
      return fail!(:invalid_callback) if forbidden.any? { |key| params.key?(key) }
      return fail!(:expired_login) unless started.is_a?(Integer) && Time.now.to_i - started <= 300 && started <= Time.now.to_i
      return fail!(:missing_session) unless session['omniauth.oidc.nonce'] && session['omniauth.oidc.pkce.verifier'] && session['omniauth.oidc.state']
      super
    rescue StandardError
      fail!(:invalid_callback)
    end

    def request_phase
      session['login_started'] = Time.now.to_i
      super
    rescue StandardError
      fail!(:login_unavailable)
    end

    def verify_id_token!(token)
      raise CallbackError.new(error: :missing_id_token) unless token
      super.tap do |verified|
        claims = verified.raw_attributes
        audience = claims['aud']
        raise CallbackError.new(error: :invalid_claims) unless claims['iat'].is_a?(Numeric)
        raise CallbackError.new(error: :invalid_claims) if audience.is_a?(Array) && audience.length > 1 && claims['azp'] != options.client_options.identifier
        raise CallbackError.new(error: :invalid_claims) if claims.key?('azp') && claims['azp'] != options.client_options.identifier
      end
    end

    # Only the verified subject enters the application; never retain auth hashes.
    def auth_hash
      OmniAuth::AuthHash.new(provider: name, uid: @verified_id_token.sub)
    end

    def config
      super.tap do |document|
        raise 'OIDC issuer mismatch' unless document.issuer == options.issuer
        %i[authorization_endpoint token_endpoint jwks_uri].each do |field|
          endpoint = URI(document.public_send(field))
          raise 'Invalid OIDC endpoint' unless endpoint.is_a?(URI::HTTPS) && endpoint.host && !endpoint.userinfo && !endpoint.fragment
        end
      end
    end

    private

    def redirect_uri
      options.fixed_redirect_uri
    end
  end
end
