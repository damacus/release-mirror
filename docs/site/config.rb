# The docs have their own dependencies and never load the catalogue application.
require 'fileutils'

set :markdown_engine, :kramdown
set :markdown, input: 'GFM', hard_wrap: false, syntax_highlighter: nil
set :http_prefix, ENV.fetch('DOCS_BASE_PATH', '/')

helpers do
  def repository_file(path)
    "https://github.com/damacus/release-mirror/blob/main/#{path}"
  end

  def guide_source(name)
    File.read(File.expand_path("../#{name}.md", root))
  end
end

after_build do
  FileUtils.cp(File.expand_path('../openapi.yaml', root), File.join(config[:build_dir], 'openapi.yaml'))
end
