require 'minitest/autorun'
require 'minitest/mock'
require 'json'
require 'net/http'
require 'tempfile'

class PublisherTest < Minitest::Test
  def setup
    @original_env = ENV.to_h
    ENV.update(
      'CATALOGUE_URL' => 'https://catalogue.example.test',
      'CATALOGUE_SERVICE' => 'widget',
      'CATALOGUE_AUDIENCE' => 'https://catalogue.example.test',
      'CATALOGUE_PAYLOAD_FILE' => '',
      'CATALOGUE_TAGS' => "v1.2.3\nactual-upstream-tag\n\n",
      'CATALOGUE_DIGEST' => "sha256:#{'a' * 64}",
      'CATALOGUE_IMMUTABLE' => 'false',
      'CATALOGUE_PLATFORMS' => JSON.generate([
        {'os' => 'linux', 'architecture' => 'arm64', 'variant' => 'v8'},
        {'os' => 'windows', 'architecture' => 'amd64', 'os.version' => '10.0.20348.2113', 'os.features' => ['win32k']}
      ]),
      'ACTIONS_ID_TOKEN_REQUEST_URL' => 'https://forge.example.test/token?job=1&audience=old',
      'ACTIONS_ID_TOKEN_REQUEST_TOKEN' => 'synthetic-request-token'
    )
  end

  def teardown
    ENV.replace(@original_env)
  end

  def test_action_inputs_preserve_exact_metadata_and_use_requested_audience
    requests = publish
    assert_equal [['job', '1'], ['audience', ENV.fetch('CATALOGUE_AUDIENCE')]], URI.decode_www_form(requests[0].uri.query)
    assert_equal 'Bearer synthetic-request-token', requests[0]['Authorization']
    assert_equal '/api/v1/services/widget/releases', requests[1].path
    assert_equal 'Bearer synthetic-workload-token', requests[1]['Authorization']
    assert_equal 'application/json', requests[1]['Content-Type']
    assert_equal({
      'tags' => ['v1.2.3', 'actual-upstream-tag'],
      'digest' => ENV.fetch('CATALOGUE_DIGEST'),
      'platforms' => JSON.parse(ENV.fetch('CATALOGUE_PLATFORMS')),
      'immutable' => false
    }, JSON.parse(requests[1].body))
  end

  def test_existing_payload_file_mode_preserves_the_supplied_json
    Tempfile.create('publication') do |file|
      payload = JSON.generate('tags' => ['actual-tag'], 'digest' => ENV.fetch('CATALOGUE_DIGEST'), 'platforms' => [], 'immutable' => true)
      file.write(payload)
      file.flush
      ENV['CATALOGUE_PAYLOAD_FILE'] = file.path
      assert_equal payload, publish[1].body
    end
  end

  def test_immutable_tags_keep_the_explicit_producer_policy
    ENV['CATALOGUE_IMMUTABLE'] = 'true'
    assert_equal true, JSON.parse(publish[1].body).fetch('immutable')
  end

  def test_publication_failure_does_not_print_tokens_or_metadata
    publish(status: '403', expected_status: 1)
  end

  private

  def publish(status: '200', expected_status: 0)
    requests = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      requests << request
      response = Struct.new(:code, :body)
      requests.length == 1 ? response.new('200', '{"value":"synthetic-workload-token"}') : response.new(status, '{}')
    end
    output, error = capture_io do
      Net::HTTP.stub(:start, ->(*_args, **_options, &block) { block.call(http) }) do
        if expected_status.zero?
          load File.expand_path('../examples/publish.rb', __dir__)
        else
          failure = assert_raises(SystemExit) { load File.expand_path('../examples/publish.rb', __dir__) }
          assert_equal expected_status, failure.status
        end
      end
    end
    assert_equal expected_status.zero? ? "Published public release metadata.\n" : '', output
    if expected_status.zero?
      assert_empty error
    else
      assert_equal "Publication failed. Check issuer configuration, service grants and the metadata allowlist. No input or credential has been printed.\n", error
    end
    requests
  end
end
