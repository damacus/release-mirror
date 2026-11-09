require_relative 'lib/release_mirror/app'
run ReleaseMirror::App.assemble(ReleaseMirror::Config.load)
