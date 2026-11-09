require 'omniauth_openid_connect'
require 'logger'

module ReleaseMirror
  # The upstream strategy allows caller-supplied nonce/verifier overrides.
  # Browser login must use only the values in the initiating session.
  class BrowserOIDC < OmniAuth::Strategies::OpenIDConnect
    option :name, 'oidc'

    def call(env)
      return @app.call(env) if env['PATH_INFO'].to_s.start_with?('/api/', '/health', '/catalogue.css')
      super
    end

    def callback_phase
      started = session.delete('login_started')
      forbidden = %w[nonce code_verifier redirect_uri id_token]
      return fail!(:invalid_callback) if forbidden.any? { |key| params.key?(key) }
      return fail!(:expired_login) unless started.is_a?(Integer) && Time.now.to_i - started <= 300 && started <= Time.now.to_i
      return fail!(:missing_session) unless session['omniauth.nonce'] && session['omniauth.pkce.verifier'] && session['omniauth.state']
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
      super
    end

    # Only the verified subject enters the application; never retain auth hashes.
    def auth_hash
      OmniAuth::AuthHash.new(provider: name, uid: decode_id_token(access_token.id_token).sub)
    end
  end
end
