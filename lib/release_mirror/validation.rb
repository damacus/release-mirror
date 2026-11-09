# typed: true
require 'json'
require 'sorbet-runtime'

module ReleaseMirror
  class Error < StandardError
    extend T::Sig
    sig { returns(Integer) }
    attr_reader :status
    sig { params(message: String, status: Integer).void }
    def initialize(message = 'Invalid request', status = 422)
      @status = status
      super(message)
    end
  end

  module Validation
    include Kernel
    extend T::Sig
    TAG = /\A[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}\z/
    ALIAS = /\A[a-z0-9][a-z0-9_-]{0,63}\z/
    COMPONENT = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/
    PATH_PART = '[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*'
    DOMAIN = '(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*|\[[a-fA-F0-9:]+\])(?::[0-9]{1,5})?'
    NAME = /\A(?:#{DOMAIN}\/)?#{PATH_PART}(?:\/#{PATH_PART})*\z/
    module_function

    sig { params(value: T.untyped, allowed: T::Array[String], required: T::Array[String]).returns(T::Hash[T.untyped, T.untyped]) }
    def object(value, allowed, required = [])
      raise Error unless value.is_a?(Hash) && (value.keys - allowed).empty? && (required - value.keys).empty?
      value
    end

    sig { params(value: T.untyped, grammar: Regexp, max: Integer).returns(String) }
    def string(value, grammar, max = 512)
      raise Error unless value.is_a?(String) && value.bytesize <= max && value.valid_encoding? && grammar.match?(value)
      value
    end

    sig { params(value: T.untyped).returns(String) }
    def service(value) = string(value, ALIAS, 64)
    sig { params(value: T.untyped).returns(String) }
    def tag(value) = string(value, TAG, 128)

    sig { params(value: T.untyped).returns(String) }
    def digest(value)
      string(value, /\A(?:sha256:[a-f0-9]{64}|sha384:[a-f0-9]{96}|sha512:[a-f0-9]{128})\z/, 135)
    end

    # The caller must discard the original body immediately after this boundary.
    # Only the tag/digest leave this method; the name is never returned.
    def reference(value)
      raise Error unless value.is_a?(String) && value.bytesize <= 512 && value.ascii_only?
      name_tag, image_digest, extra = value.split('@', -1)
      raise Error if extra || name_tag.nil?
      digest(image_digest) if image_digest
      last = name_tag.split('/').last.to_s
      image_tag = last.include?(':') ? last.split(':', -1).last : nil
      name = image_tag ? name_tag.delete_suffix(":#{image_tag}") : name_tag
      raise Error unless name.bytesize <= 255 && NAME.match?(name)
      tag(image_tag) if image_tag
      raise Error unless image_tag || image_digest
      [image_tag, image_digest]
    end

    def platforms(value)
      raise Error unless value.is_a?(Array) && value.size.between?(1, 32)
      result = value.map do |item|
        object(item, %w[os architecture variant os.version os.features], %w[os architecture])
        item.each do |key, val|
          if key == 'os.features'
            raise Error unless val.is_a?(Array) && val.size <= 16 && val.uniq == val
            val.each { |feature| string(feature, COMPONENT, 64) }
          else
            string(val, COMPONENT, 64)
          end
        end
        item.sort.to_h
      end
      raise Error unless result.uniq == result
      result.sort_by { |item| JSON.generate(item) }
    end

    def release(value)
      object(value, %w[tags digest platforms reference immutable], %w[platforms])
      image_tag, image_digest = reference(value['reference']) if value.key?('reference')
      tags = value.fetch('tags', image_tag ? [image_tag] : nil)
      raise Error unless tags.is_a?(Array) && tags.size.between?(1, 32) && tags.uniq == tags
      tags.each { |item| tag(item) }
      raise Error if image_tag && !tags.include?(image_tag)
      image_digest_value = digest(value.fetch('digest', image_digest))
      raise Error if image_digest && image_digest != image_digest_value
      immutable = value.fetch('immutable', false)
      raise Error unless [true, false].include?(immutable)
      {tags: tags, digest: image_digest_value, platforms: platforms(value['platforms']), immutable: immutable}
    end

    def identity(value)
      object(value, %w[kind issuer subject], %w[kind issuer subject])
      raise Error unless %w[human workload].include?(value['kind'])
      string(value['issuer'], /\Ahttps:\/\/[^\s?#]+\z/, 512)
      string(value['subject'], /\A[^\x00-\x20\x7f]{1,256}\z/, 256)
      value
    end
  end
end
