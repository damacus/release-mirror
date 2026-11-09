require_relative 'test_helper'

class ValidationTest < Minitest::Test
  include Fixtures

  def test_reference_extracts_exact_tag_and_digest_and_rejects_mismatches
    reference = "registry.example.test:5000/private/widget:v1.0.0@#{release['digest']}"
    assert_equal ['v1.0.0', release['digest']], ReleaseMirror::Validation.reference(reference)
    assert_equal [nil, release['digest']], ReleaseMirror::Validation.reference("private/widget@#{release['digest']}")
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Validation.release(release(['different']).merge('reference' => reference)) }
    assert_raises(ReleaseMirror::Error) { ReleaseMirror::Validation.release(release(['v1.0.0'], 'b').merge('reference' => reference)) }
    ['private/widget', 'private/widget:bad tag', 'private/widget:v1@sha256:bad', 'https://private/widget:v1', 'private/widget:v1@sha256:abc@extra'].each do |value|
      assert_raises(ReleaseMirror::Error) { ReleaseMirror::Validation.reference(value) }
    end
  end

  def test_platforms_require_unique_valid_public_metadata
    platform = {'os' => 'linux', 'architecture' => 'arm64', 'variant' => 'v8', 'os.features' => ['feature1']}
    assert_equal [platform], ReleaseMirror::Validation.platforms([platform])
    [[], [platform, platform], [platform.merge('os.features' => ['feature1', 'feature1'])], [platform.merge('os.features' => ['bad feature'])], [{'os' => 'linux'}], [platform.merge('secret' => 'private')]].each do |value|
      assert_raises(ReleaseMirror::Error) { ReleaseMirror::Validation.platforms(value) }
    end
  end
end
