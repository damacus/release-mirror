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

  def test_add_edit_delete_matrix_and_atomic_multi_tag
    grant(BUILD, ['add'])
    store.publish(BUILD, 'widget', release)
    assert_equal 403, assert_raises(ReleaseMirror::Error) { store.publish(BUILD, 'widget', release(['new-tag', 'v1.0.0'], 'b')) }.status
    assert_equal ['v1.0.0'], store.releases('widget').map { |r| r['version'] }
    assert_raises(ReleaseMirror::Error) { store.delete_release(BUILD, 'widget', 'v1.0.0') }
    assert_raises(ReleaseMirror::Error) { store.create_service(BUILD, 'other') }
    grant(BUILD, %w[edit delete])
    store.publish(BUILD, 'widget', release(['v1.0.0'], 'b'))
    store.delete_release(BUILD, 'widget', 'v1.0.0')
    assert_empty store.releases('widget')
    assert_empty store.db[:releases].all
    refute store.allowed?(BUILD, 'admin', 'widget')
    refute store.allowed?(HUMAN, 'add', 'widget')
  end

  def test_global_writer_and_scoped_admin
    grant(BUILD, %w[add edit delete], '*')
    store.create_service(BUILD, 'other')
    store.publish(BUILD, 'other', release)
    grant(HUMAN, ['admin'])
    assert store.allowed?(HUMAN, 'edit', 'widget')
    refute store.allowed?(HUMAN, 'admin', '*')
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
end
