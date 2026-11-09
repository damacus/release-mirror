require_relative 'test_helper'

class CatalogueTest < Minitest::Test
  include Fixtures
  def setup = store.create_service(ADMIN, 'widget')
  def teardown = store.db.disconnect

  def test_exact_tags_moving_and_immutable
    tags = ['v1.2.3', 'PR_27.test-1', 'latest']
    first = store.publish(ADMIN, 'widget', release(tags))
    assert_equal tags.sort, first.map { |r| r['version'] }
    second = store.publish(ADMIN, 'widget', release(tags, 'b'))
    assert_equal first[0]['publishedAt'], second[0]['publishedAt']
    refute_equal first[0]['updatedAt'], second[0]['updatedAt']
    fixed = release(['upstream-fixed']).merge('immutable' => true)
    store.publish(ADMIN, 'widget', fixed)
    assert_equal 409, assert_raises(ReleaseMirror::Error) { store.publish(ADMIN, 'widget', fixed.merge('digest' => release([], 'b')['digest'])) }.status
    assert_equal release['digest'], store.releases('widget').find { |r| r['version'] == 'upstream-fixed' }['digest']
  end

  def test_reference_never_survives_validation
    body = release.merge('reference' => "registry.example.test:5000/private/widget:v1.0.0@#{release['digest']}")
    value = ReleaseMirror::Validation.release(body)
    refute_includes value.to_s, 'private'
    store.publish(ADMIN, 'widget', body)
    refute_includes store.export.to_json, 'registry'
    refute_includes store.db[:releases].all.to_s, 'private'
    no_explicit_tag = body.reject { |key, _| %w[tags digest].include?(key) }
    assert_equal ['v1.0.0'], ReleaseMirror::Validation.release(no_explicit_tag)[:tags]
  end

  def test_invalid_inputs_are_generic
    invalid = [release.merge('source' => 'TOP_SECRET'), release.merge('digest' => 'a' * 40), release(['bad tag']), release(['a' * 129]), release.merge('platforms' => [{'os' => 'linux', 'architecture' => 'arm64', 'annotations' => {}}]), release.merge('reference' => 'https://registry.example.test/x:v1.0.0')]
    invalid.each do |body|
      error = assert_raises(ReleaseMirror::Error) { store.publish(ADMIN, 'widget', body) }
      assert_equal 'Invalid request', error.message
    end
    assert_empty store.releases('widget')
  end

  def test_publisher_adds_and_updates_only_its_service
    grant(BUILD, ['publish'])
    store.publish(BUILD, 'widget', release)
    store.publish(BUILD, 'widget', release(['new-tag', 'v1.0.0'], 'b'))
    assert_equal ['new-tag', 'v1.0.0'], store.releases('widget').map { |r| r['version'] }
    assert_raises(ReleaseMirror::Error) { store.delete_release(BUILD, 'widget', 'v1.0.0') }
    assert_raises(ReleaseMirror::Error) { store.create_service(BUILD, 'other') }
    store.create_service(ADMIN, 'other')
    assert_raises(ReleaseMirror::Error) { store.publish(BUILD, 'other', release) }
    refute store.allowed?(BUILD, 'admin', 'widget')
    refute store.allowed?(HUMAN, 'add', 'widget')
  end

  def test_global_admin_and_legacy_grants_fail_closed
    assert_raises(ReleaseMirror::Error) { grant(BUILD, ['publish'], '*') }
    assert_raises(ReleaseMirror::Error) { grant(HUMAN, ['admin'], 'widget') }
    grant(HUMAN, ['admin'], '*')
    assert store.allowed?(HUMAN, 'edit', 'widget')
    assert store.allowed?(HUMAN, 'admin', '*')
    store.db[:grants].insert(**BUILD.transform_keys(&:to_sym), scope: 'widget', action: 'edit')
    refute store.allowed?(BUILD, 'edit', 'widget')
    assert_raises(ReleaseMirror::Error) { grant_body = {'identity' => BUILD, 'scope' => '*', 'actions' => ['admin']}; store.grant(HUMAN, grant_body) }
  end

  def test_export_import_and_atomic_rejection
    store.publish(ADMIN, 'widget', release)
    original = store.export
    copy = ReleaseMirror::Store.new(':memory:', bootstrap: ADMIN)
    copy.import(ADMIN, original)
    assert_equal original, copy.export
    bad = Marshal.load(Marshal.dump(original))
    bad['services'] << {'name' => 'extra', 'releases' => [{'secret' => 'NO'}]}
    assert_raises(ReleaseMirror::Error) { copy.import(ADMIN, bad) }
    refute copy.exists?('extra')
  ensure
    copy&.db&.disconnect
  end

  def test_restart_and_backup_restore
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'catalogue.sqlite3')
      persistent = ReleaseMirror::Store.new(path, bootstrap: ADMIN)
      persistent.create_service(ADMIN, 'widget')
      persistent.publish(ADMIN, 'widget', release)
      snapshot = persistent.export
      backup = File.join(directory, 'backup.sqlite3')
      persistent.db.run("VACUUM INTO '#{backup}'")
      persistent.delete_release(ADMIN, 'widget', 'v1.0.0')
      persistent.db.disconnect
      persistent = ReleaseMirror::Store.new(path, bootstrap: ADMIN)
      assert_empty persistent.releases('widget')
      restored = ReleaseMirror::Store.new(backup, bootstrap: ADMIN)
      assert_equal snapshot, restored.export
      restored.db.disconnect
      persistent.db.disconnect
    end
  end

  def test_missing_and_duplicate_resources_return_conflict_or_not_found
    assert_equal 409, assert_raises(ReleaseMirror::Error) { store.create_service(ADMIN, 'widget') }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { store.releases('missing') }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { store.publish(ADMIN, 'missing', release) }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { store.delete_release(ADMIN, 'widget', 'missing') }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { store.delete_service(ADMIN, 'missing') }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { grant(BUILD, ['publish'], 'missing') }.status
    assert_equal 404, assert_raises(ReleaseMirror::Error) { store.revoke(ADMIN, 999) }.status
  end

  def test_deleting_service_removes_releases_and_grants
    grant(BUILD, ['publish'])
    store.publish(BUILD, 'widget', release)
    store.delete_service(ADMIN, 'widget')
    refute store.exists?('widget')
    assert_empty store.db[:releases].where(service: 'widget').all
    assert_empty store.db[:grants].where(scope: 'widget').all
    store.create_service(ADMIN, 'widget')
    assert_raises(ReleaseMirror::Error) { store.publish(BUILD, 'widget', release) }
  end

  def test_import_rejects_duplicate_records_and_bad_timestamps_atomically
    store.publish(ADMIN, 'widget', release)
    original = store.export
    cases = [
      ->(d) { d['schemaVersion'] = 2 },
      ->(d) { d['services'] << Marshal.load(Marshal.dump(d['services'].first)) },
      ->(d) { d['services'].first['releases'] = 'not-an-array' },
      ->(d) { d['services'].first['releases'].first['service'] = 'other' },
      ->(d) { d['services'].first['releases'] << d['services'].first['releases'].first.dup },
      ->(d) { d['services'].first['releases'].first['updatedAt'] = '2000-01-01T00:00:00Z' },
      ->(d) { d['services'].first['releases'].first['publishedAt'] = '2024-99-99T00:00:00Z' }
    ]
    cases.each do |change|
      document = Marshal.load(Marshal.dump(original))
      change.call(document)
      assert_raises(ReleaseMirror::Error) { store.import(ADMIN, document) }
      assert_equal original, store.export
    end
  end

  def test_import_existing_immutable_release_preserves_policy
    store.publish(ADMIN, 'widget', release.merge('immutable' => true))
    snapshot = store.export
    store.import(ADMIN, snapshot)
    assert_equal snapshot, store.export
    assert_equal 409, assert_raises(ReleaseMirror::Error) { store.publish(ADMIN, 'widget', release(['v1.0.0'], 'b')) }.status
  end
end
