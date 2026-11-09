#!/usr/bin/env ruby
# Check only generated local destinations; never fetch external example URLs.
require 'cgi'
require 'pathname'
require 'uri'

root = Pathname.new(ARGV.fetch(0, File.join(__dir__, 'build'))).expand_path
prefix = '/' + ARGV.fetch(1, '/').split('/').reject(&:empty?).join('/')
prefix = '' if prefix == '/'
errors = []
pages = Dir[root.join('**/*.html')]
abort 'No generated documentation pages found.' if pages.empty?

pages.each do |page|
  source = Pathname.new(page).relative_path_from(root).to_s
  html = File.read(page)
  html.scan(/\b(?:href|src)="([^"]+)"/).flatten.each do |value|
    value = CGI.unescapeHTML(value)
    link = URI.parse(value)
    next if link.scheme || link.host

    path = URI::DEFAULT_PARSER.unescape(link.path.to_s)
    if path.start_with?('/')
      unless prefix.empty? || path == prefix || path.start_with?("#{prefix}/")
        errors << "#{source}: link escapes site prefix: #{value}"
        next
      end
      relative = path.delete_prefix(prefix).delete_prefix('/')
    else
      relative = path.empty? ? source : File.join(File.dirname(source), path)
    end
    target = root.join(relative).cleanpath
    target = target.join('index.html') if target.directory?
    unless target.to_s.start_with?("#{root}/") && target.file?
      errors << "#{source}: missing local destination: #{value}"
      next
    end
    next if link.fragment.nil? || link.fragment.empty? || target.extname != '.html'

    anchor = URI::DEFAULT_PARSER.unescape(link.fragment)
    ids = File.read(target).scan(/\bid="([^"]+)"/).flatten.map { |id| CGI.unescapeHTML(id) }
    errors << "#{source}: missing anchor: #{value}" unless ids.include?(anchor)
  rescue URI::InvalidURIError
    errors << "#{source}: malformed link: #{value}"
  end
end

abort errors.join("\n") unless errors.empty?
puts "Checked local links, anchors and assets in #{pages.length} documentation pages."
