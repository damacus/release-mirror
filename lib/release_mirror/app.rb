require 'sinatra/base'
require 'rack/session/cookie'
require 'securerandom'
require 'cgi/escape'
require_relative 'store'
require_relative 'auth'
require_relative 'config'
require_relative 'version'

module ReleaseMirror
  # Public reads never initialise the browser login stack. Once a login starts,
  # keep one middleware instance for subsequent callbacks and sign-ins.
  class LazyBrowserOIDC
    def initialize(app, **options)
      @app = app
      @options = options
      @mutex = Mutex.new
    end

    def call(env)
      return @app.call(env) unless ['/auth/oidc', '/auth/oidc/callback'].include?(env['PATH_INFO'])

      middleware = @mutex.synchronize do
        @middleware ||= begin
          require_relative 'oidc'
          OmniAuth.config.logger = Logger.new(File::NULL)
          OmniAuth.config.on_failure = ->(_env) { [401, {'content-type' => 'application/json', 'cache-control' => 'no-store'}, ['{"error":"Login failed"}']] }
          # Boundary checks the browser session's CSRF token before this middleware.
          OmniAuth.config.request_validation_phase = ->(_env) {}
          BrowserOIDC.new(@app, **@options)
        end
      end
      middleware.call(env)
    end
  end

  class BrowserSessions
    def initialize(app, **options)
      @app = app
      @browser = Rack::Session::Cookie.new(app, **options)
    end

    def call(env)
      env['PATH_INFO'].to_s.start_with?('/api/', '/health', '/catalogue.css') ? @app.call(env) : @browser.call(env)
    end
  end

  # Runs before OAuth and Sinatra: bounds even chunked bodies, rejects unknown
  # hosts, and checks every browser mutation before any middleware can act.
  class Boundary
    MAX_BODY = 1_048_576
    def initialize(app, config)
      @app = app
      @origin = URI(config.fetch('publicUrl'))
    end

    def call(env)
      request = Rack::Request.new(env)
      return response(400, 'Invalid request') if env['PATH_INFO'].to_s.bytesize > 2048 || env['QUERY_STRING'].to_s.bytesize > 4096
      authority = env['HTTP_HOST'].to_s
      return response(403, 'Forbidden') unless authority.match?(/\A#{Regexp.escape(@origin.host)}(?::[0-9]{1,5})?\z/i)
      body = env['rack.input']&.read(MAX_BODY + 1).to_s
      return response(413, 'Request too large') if body.bytesize > MAX_BODY
      env['rack.input'] = StringIO.new(body)
      if request.path.start_with?('/api/', '/health', '/catalogue.css')
        # API writes never use cookie authentication, so no browser CSRF bypass.
        # Leave the lazy cookie session untouched so public JSON never emits a
        # session cookie that could be shared by an intermediary cache.
      else
        session = env.fetch('rack.session')
        session['csrf'] ||= SecureRandom.hex(32)
        unless %w[GET HEAD OPTIONS].include?(request.request_method)
          return response(403, 'Forbidden') unless request.media_type == 'application/x-www-form-urlencoded'
          csrf = request.POST['csrf']
          return response(403, 'Forbidden') unless csrf.is_a?(String) && Rack::Utils.secure_compare(session['csrf'], csrf)
          origin = env['HTTP_ORIGIN']
          return response(403, 'Forbidden') if origin && origin != @origin.to_s.delete_suffix('/')
        end
      end
      status, headers, result = @app.call(env)
      headers['x-content-type-options'] = 'nosniff'
      headers['referrer-policy'] = 'no-referrer'
      headers['content-security-policy'] = "default-src 'none'; style-src 'self'; form-action 'self' #{@origin.scheme == 'https' ? 'https:' : 'http: https:'}; frame-ancestors 'none'; base-uri 'none'"
      headers['cache-control'] = request.path.start_with?('/api/v1/services', '/api/v1/export') && %w[GET HEAD].include?(request.request_method) ? 'public, max-age=0, must-revalidate' : 'no-store'
      [status, headers, result]
    rescue StandardError
      response(400, 'Invalid request')
    end

    def response(status, message)
      [status, {'content-type' => 'application/json', 'cache-control' => 'no-store'}, [JSON.generate(error: message)]]
    end
  end

  class App < Sinatra::Base
    set :root, File.expand_path('../..', __dir__)
    set :views, File.expand_path('../../views', __dir__)
    set :public_folder, File.expand_path('../../public', __dir__)
    set :logging, false
    set :dump_errors, false
    set :show_exceptions, false
    set :raise_errors, false
    set :host_authorization, {permitted_hosts: []} # Exact host checked by Boundary.

    helpers do
      def store = settings.catalogue
      def h(value) = CGI.escapeHTML(value.to_s)
      def csrf = %(<input type="hidden" name="csrf" value="#{h(session['csrf'])}">)
      def identity
        return @identity if defined?(@identity)
        if request.path.start_with?('/api/')
          header = request.env['HTTP_AUTHORIZATION']
          @identity = if header
            raise Error.new('Invalid credential', 401) unless header.start_with?('Bearer ') && header.count(' ') == 1
            settings.authenticator.authenticate(header.delete_prefix('Bearer '))
          end
        else
          started = session['authenticated_at']
          @identity = started.is_a?(Integer) && started <= Time.now.to_i && Time.now.to_i - started < 3600 ? session['identity'] : nil
        end
      end
      def can?(action, service = '*') = store.allowed?(identity, action, service)
      def json_body
        raise Error.new('Use application/json', 415) unless request.media_type == 'application/json'
        JSON.parse(request.body.read, max_nesting: 16)
      rescue JSON::ParserError
        raise Error.new('Invalid JSON', 400)
      end
      def json(value)
        content_type :json
        JSON.generate(value)
      end
      def form_release
        {'tags' => params.fetch('tags', '').split(',').map(&:strip), 'digest' => params['digest'],
         'platforms' => JSON.parse(params.fetch('platforms', '[]'), max_nesting: 8), 'immutable' => params['immutable'] == 'true'}
      rescue JSON::ParserError
        raise Error
      end
    end

    error Error do
      error = env['sinatra.error']
      status error.status
      json(error: error.message)
    end
    error do
      status 500
      json(error: 'Internal error')
    end
    not_found { json(error: 'Not found') }

    get('/health') { json(status: 'ok') }
    get('/api/v1/services') { json(services: store.services) }
    get '/api/v1/services/:service/releases' do
      json(service: params[:service], releases: store.releases(params[:service]))
    end
    get '/api/v1/services/:service/renovate' do
      json(releases: store.releases(params[:service]).map { |r| {'version' => r['version'], 'digest' => r['digest'], 'releaseTimestamp' => r['publishedAt']} })
    end
    get '/api/v1/services/:service/releases/:tag' do
      row = store.releases(params[:service]).find { |r| r['version'] == params[:tag] }
      raise Error.new('Not found', 404) unless row
      json(row)
    end
    post '/api/v1/services' do
      body = Validation.object(json_body, ['name'], ['name'])
      store.create_service(identity, body['name'])
      status 201
      json(name: body['name'])
    end
    delete '/api/v1/services/:service' do
      store.delete_service(identity, params[:service])
      status 204
    end
    post '/api/v1/services/:service/releases' do
      result = store.publish(identity, params[:service], json_body)
      json(releases: result)
    end
    delete '/api/v1/services/:service/releases/:tag' do
      store.delete_release(identity, params[:service], params[:tag])
      status 204
    end
    get('/api/v1/export') { json(store.export) }
    post '/api/v1/import' do
      store.import(identity, json_body)
      status 204
    end
    get '/api/v1/grants' do
      json(grants: store.grants(identity, params.fetch('scope', '*')))
    end
    post '/api/v1/grants' do
      store.grant(identity, json_body)
      status 204
    end
    delete '/api/v1/grants/:id' do
      raise Error unless /\A[1-9][0-9]{0,18}\z/.match?(params[:id])
      store.revoke(identity, params[:id].to_i)
      status 204
    end

    get '/' do
      @services = store.services
      erb :index
    end
    get '/services/:service' do
      @service = params[:service]
      @releases = store.releases(@service)
      erb :service
    end
    post '/services' do
      store.create_service(identity, params['name'])
      redirect "/services/#{params['name']}", 303
    end
    post '/services/:service/releases' do
      store.publish(identity, params[:service], form_release)
      redirect "/services/#{params[:service]}", 303
    end
    post '/services/:service/releases/:tag/delete' do
      store.delete_release(identity, params[:service], params[:tag])
      redirect "/services/#{params[:service]}", 303
    end
    post '/services/:service/delete' do
      store.delete_service(identity, params[:service])
      redirect '/', 303
    end
    get '/permissions' do
      @scope = params.fetch('scope', '*')
      @grants = store.grants(identity, @scope)
      erb :permissions
    end
    post '/permissions' do
      role = params['role']
      raise Error unless %w[admin publish].include?(role)
      kind = role == 'admin' ? 'human' : 'workload'
      scope = role == 'admin' ? '*' : params['scope']
      store.grant(identity, {'identity' => {'kind' => kind, 'issuer' => params['issuer'], 'subject' => params['subject']}, 'scope' => scope, 'actions' => [role]})
      redirect "/permissions?scope=#{CGI.escape(params['scope'])}", 303
    end
    post '/permissions/:id/delete' do
      raise Error unless /\A[1-9][0-9]{0,18}\z/.match?(params[:id])
      store.revoke(identity, params[:id].to_i)
      redirect '/', 303
    end
    get '/auth/oidc/callback' do
      auth = env.delete('omniauth.auth')
      raise Error.new('Invalid login', 401) unless auth && auth['provider'] == 'oidc' && settings.runtime_config['browserOidc']
      person = Validation.identity({'kind' => 'human', 'issuer' => settings.runtime_config['browserOidc']['issuer'], 'subject' => auth['uid']})
      session.clear
      request.env['rack.session.options'][:renew] = true
      session['identity'] = person
      session['authenticated_at'] = Time.now.to_i
      session['csrf'] = SecureRandom.hex(32)
      redirect '/', 303
    end
    post '/logout' do
      session.clear
      request.env['rack.session.options'][:renew] = true
      redirect '/', 303
    end

    def self.assemble(config, catalogue: nil, authenticator: nil)
      Config.validate(config)
      secret = ENV.fetch(config.fetch('sessionSecretEnv'))
      raise Error.new('Session secret must be at least 64 bytes', 500) if secret.bytesize < 64
      catalogue ||= Store.new(config.fetch('databasePath', 'data/catalogue.sqlite3'), bootstrap: config['bootstrap'])
      klass = Class.new(self)
      klass.set :catalogue, catalogue
      klass.set :authenticator, authenticator || Auth.new(config)
      klass.set :runtime_config, config
      secure = config['publicUrl'].start_with?('https://')
      Rack::Builder.new do
        use BrowserSessions, key: 'release_mirror', secret: secret, secure: secure, httponly: true, same_site: :lax, expire_after: 3600
        use Boundary, config
        if (provider = config['browserOidc'])
          use LazyBrowserOIDC, issuer: provider['issuer'], scope: [:openid], response_type: 'code', require_state: true, send_nonce: true, pkce: true, fetch_user_info: false,
            client_signing_alg: provider.fetch('signingAlgorithm', 'RS256'),
            fixed_redirect_uri: "#{config['publicUrl'].delete_suffix('/')}/auth/oidc/callback",
            client_options: {identifier: provider['clientId'], secret: ENV.fetch(provider['clientSecretEnv']), config_endpoint: "#{provider['issuer'].delete_suffix('/')}/.well-known/openid-configuration"}
        end
        run klass
      end.to_app
    end
  end
end
