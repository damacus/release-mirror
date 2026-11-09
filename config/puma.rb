bind "tcp://0.0.0.0:#{ENV.fetch('PORT', '9292')}"
workers 0
threads 1, 5
# No access logger: callback URLs, tokens and request bodies must not be logged.
quiet
