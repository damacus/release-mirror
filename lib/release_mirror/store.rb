require 'sequel'
require 'sqlite3'
require 'time'
require 'fileutils'
require_relative 'validation'

module ReleaseMirror
  class Store
    ACTIONS = %w[add edit delete admin].freeze
    attr_reader :db

    def initialize(path, bootstrap: nil)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700) unless path == ':memory:'
      @db = Sequel.sqlite(path, max_connections: 1, timeout: 5000)
      @db.run('PRAGMA journal_mode=WAL')
      @db.run('PRAGMA secure_delete=ON')
      @bootstrap = bootstrap
      schema
    end

    def schema
      @db.create_table?(:services) { String :name, primary_key: true }
      @db.create_table?(:releases) do
        String :service, null: false
        String :version, null: false
        String :digest, null: false
        String :platforms, text: true, null: false
        TrueClass :immutable, null: false, default: false
        String :published_at, null: false
        String :updated_at, null: false
        primary_key %i[service version]
        foreign_key [:service], :services, key: :name, on_delete: :cascade
      end
      @db.create_table?(:grants) do
        primary_key :id
        String :kind, null: false
        String :issuer, null: false
        String :subject, null: false
        String :scope, null: false
        String :action, null: false
        unique %i[kind issuer subject scope action]
      end
    end

    def allowed?(identity, action, service = '*')
      return false unless identity && ACTIONS.include?(action)
      return true if @bootstrap && identity == @bootstrap
      base = @db[:grants].where(identity.transform_keys(&:to_sym))
      return true if identity['kind'] == 'human' && base.where(scope: '*', action: 'admin').count.positive?
      identity['kind'] == 'workload' && service != '*' && %w[add edit].include?(action) &&
        base.where(scope: service, action: 'publish').count.positive?
    end

    def require!(identity, action, service = '*')
      raise Error.new(identity ? 'Forbidden' : 'Authentication required', identity ? 403 : 401) unless allowed?(identity, action, service)
    end

    def services = @db[:services].order(:name).select_map(:name)
    def exists?(service) = @db[:services].where(name: service).count.positive?

    def create_service(identity, service)
      Validation.service(service)
      @db.transaction(mode: :immediate) do
        require!(identity, 'add')
        raise Error.new('Conflict', 409) if exists?(service)
        @db[:services].insert(name: service)
      end
    end

    def delete_service(identity, service)
      @db.transaction(mode: :immediate) do
        require!(identity, 'delete', service)
        raise Error.new('Not found', 404) unless exists?(service)
        @db[:releases].where(service: service).delete
        @db[:grants].where(scope: service).delete
        @db[:services].where(name: service).delete
      end
    end

    def releases(service)
      raise Error.new('Not found', 404) unless exists?(service)
      @db[:releases].where(service: service).order(:version).all.map { |row| public_release(row) }
    end

    def public_release(row)
      {'service' => row[:service], 'version' => row[:version], 'digest' => row[:digest],
       'platforms' => JSON.parse(row[:platforms]), 'publishedAt' => row[:published_at], 'updatedAt' => row[:updated_at]}
    end

    def publish(identity, service, input)
      Validation.service(service)
      release = Validation.release(input)
      @db.transaction(mode: :immediate) do
        raise Error.new('Not found', 404) unless exists?(service)
        release[:tags].each do |tag|
          rows = @db[:releases].where(service: service, version: tag)
          old = rows.first
          require!(identity, old ? 'edit' : 'add', service)
          attrs = {digest: release[:digest], platforms: JSON.generate(release[:platforms]), immutable: release[:immutable]}
          if old
            raise Error.new('Immutable tag conflict', 409) if old[:immutable] && (old[:digest] != attrs[:digest] || old[:platforms] != attrs[:platforms] || !attrs[:immutable])
            rows.update(**attrs, updated_at: Time.now.utc.iso8601(6)) unless attrs.all? { |key, val| old[key] == val }
          else
            now = Time.now.utc.iso8601(6)
            rows.insert(**attrs, service: service, version: tag, published_at: now, updated_at: now)
          end
        end
      end
      releases(service).select { |row| release[:tags].include?(row['version']) }
    end

    def delete_release(identity, service, tag)
      Validation.service(service)
      Validation.tag(tag)
      @db.transaction(mode: :immediate) do
        require!(identity, 'delete', service)
        raise Error.new('Not found', 404) if @db[:releases].where(service: service, version: tag).delete.zero?
      end
    end

    def grants(identity, scope = '*')
      require!(identity, 'admin', scope)
      @db[:grants].where(scope: scope).order(:id).all
    end

    def grant(identity, input)
      Validation.object(input, %w[identity scope actions], %w[identity scope actions])
      target = Validation.identity(input['identity'])
      scope = input['scope']
      Validation.service(scope) unless scope == '*'
      actions = input['actions']
      valid_admin = target['kind'] == 'human' && scope == '*' && actions == ['admin']
      valid_publisher = target['kind'] == 'workload' && scope != '*' && actions == ['publish']
      raise Error unless valid_admin || valid_publisher
      @db.transaction(mode: :immediate) do
        require!(identity, 'admin', scope)
        raise Error.new('Not found', 404) unless scope == '*' || exists?(scope)
        actions.each { |action| @db[:grants].insert_conflict.insert(**target.transform_keys(&:to_sym), scope: scope, action: action) }
      end
    end

    def revoke(identity, id)
      @db.transaction(mode: :immediate) do
        row = @db[:grants].where(id: id).first
        raise Error.new('Not found', 404) unless row
        require!(identity, 'admin', row[:scope])
        @db[:grants].where(id: id).delete
      end
    end

    def export
      @db.transaction do
        {'schemaVersion' => 1, 'services' => services.map { |name| {'name' => name, 'releases' => releases(name)} }}
      end
    end

    def import(identity, document)
      Validation.object(document, %w[schemaVersion services], %w[schemaVersion services])
      raise Error unless document['schemaVersion'] == 1 && document['services'].is_a?(Array) && document['services'].size <= 1000
      @db.transaction(mode: :immediate) do
        names = []
        document['services'].each do |service|
          Validation.object(service, %w[name releases], %w[name releases])
          name = Validation.service(service['name'])
          raise Error if names.include?(name)
          names << name
          create_service(identity, name) unless exists?(name)
          raise Error unless service['releases'].is_a?(Array) && service['releases'].size <= 10000
          tags = []
          service['releases'].each do |row|
            Validation.object(row, %w[service version digest platforms publishedAt updatedAt], %w[service version digest platforms publishedAt updatedAt])
            raise Error unless row['service'] == name && !tags.include?(row['version'])
            tags << row['version']
            times = %w[publishedAt updatedAt].map { |key| Validation.string(row[key], /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z\z/, 40); Time.iso8601(row[key]) }
            raise Error if times[1] < times[0]
            existing = @db[:releases].where(service: name, version: row['version']).first
            publish(identity, name, {'tags' => [row['version']], 'digest' => row['digest'], 'platforms' => row['platforms'], 'immutable' => existing ? existing[:immutable] : false})
            @db[:releases].where(service: name, version: row['version']).update(published_at: row['publishedAt'], updated_at: row['updatedAt']) unless existing
          end
        end
      end
    rescue ArgumentError
      raise Error
    end
  end
end
