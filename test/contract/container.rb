# Disposable portability test. Requires a built image and local Docker daemon.
require 'open3'
require 'json'
require 'tmpdir'
require 'securerandom'
require 'net/http'

name = "release-mirror-test-#{SecureRandom.hex(5)}"
image = ENV.fetch('CONTAINER_IMAGE', 'release-mirror:local')
port = ENV.fetch('CONTAINER_TEST_PORT', '19392')
environment = {'SESSION_SECRET' => SecureRandom.hex(64)}
docker = lambda do |*arguments|
  out, err, result = Open3.capture3(environment, 'docker', *arguments)
  raise "Container operation failed: #{arguments.first}\n#{err.lines.last(4).join}" unless result.success?
  out
end
get = lambda do |path|
  uri = URI("http://localhost:#{port}#{path}")
  Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |http| http.get(uri.request_uri) }
end
wait = lambda do
  ready = 50.times.any? do
    begin
      response = get.call('/health')
      response.code == '200'
    rescue SystemCallError, IOError
      sleep 0.1
      false
    end
  end
  raise 'Container did not become ready' unless ready
end
Dir.mktmpdir('release-mirror-container-') do |directory|
  begin
    config = {'publicUrl' => 'http://localhost:9292', 'databasePath' => '/data/catalogue.sqlite3', 'sessionSecretEnv' => 'SESSION_SECRET'}
    path = File.join(directory, 'config.json')
    File.write(path, JSON.generate(config))
    docker.call('volume', 'create', name)
    docker.call('run', '--detach', '--name', name, '--read-only', '--tmpfs', '/tmp', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--env', 'SESSION_SECRET', '--publish', "127.0.0.1:#{port}:9292", '--mount', "type=volume,src=#{name},dst=/data", '--mount', "type=bind,src=#{path},dst=/config/config.json,readonly", image)
    wait.call
    seed = <<~'RUBY'
      require_relative 'lib/release_mirror/store'
      person = {'kind'=>'human','issuer'=>'https://identity.example.test','subject'=>'fixture'}
      store = ReleaseMirror::Store.new('/data/catalogue.sqlite3', bootstrap: person)
      store.create_service(person, 'portable')
      store.publish(person, 'portable', {'tags'=>['v1.0.0'],'digest'=>'sha256:' + 'a'*64,'platforms'=>[{'os'=>'linux','architecture'=>'amd64'}]})
      store.db.run("VACUUM INTO '/data/backup.sqlite3'")
    RUBY
    docker.call('exec', name, 'ruby', '-rbundler/setup', '-e', seed)
    expected = JSON.parse(get.call('/api/v1/export').body)
    docker.call('restart', name)
    wait.call
    raise 'Mounted metadata did not survive restart' unless JSON.parse(get.call('/api/v1/export').body) == expected
    docker.call('exec', name, 'ruby', '-rbundler/setup', '-e', "require_relative 'lib/release_mirror/store'; s=ReleaseMirror::Store.new('/data/catalogue.sqlite3'); s.db[:releases].delete")
    raise 'Deletion did not remove live entry' unless JSON.parse(get.call('/api/v1/services/portable/releases').body)['releases'].empty?
    docker.call('stop', name)
    docker.call('run', '--rm', '--mount', "type=volume,src=#{name},dst=/data", '--entrypoint', 'ruby', image, '-rfileutils', '-e', "FileUtils.cp('/data/backup.sqlite3','/data/catalogue.sqlite3'); %w[-wal -shm].each{|suffix|FileUtils.rm_f('/data/catalogue.sqlite3'+suffix)}")
    docker.call('start', name)
    wait.call
    raise 'Backup restoration did not restore deleted entry' unless JSON.parse(get.call('/api/v1/export').body) == expected
    user = docker.call('exec', name, 'id', '-u').strip
    raise 'Container unexpectedly runs as root' unless user == '10001'
    puts 'Container contract passed: non-root, read-only root, mounted restart persistence, live deletion and backup restoration.'
  ensure
    Open3.capture3('docker', 'rm', '--force', name)
    Open3.capture3('docker', 'volume', 'rm', name)
  end
end
