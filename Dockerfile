FROM ruby:3.4.9-slim AS dependencies
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libsqlite3-dev && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle config set without test && bundle install --jobs 4

FROM ruby:3.4.9-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates && rm -rf /var/lib/apt/lists/* && groupadd --gid 10001 mirror && useradd --uid 10001 --gid mirror --no-create-home mirror
WORKDIR /app
COPY --from=dependencies /usr/local/bundle /usr/local/bundle
COPY . .
RUN mkdir -p /data && chown mirror:mirror /data
ENV RACK_ENV=production BUNDLE_WITHOUT=test CONFIG_FILE=/config/config.json
USER 10001:10001
VOLUME /data
EXPOSE 9292
HEALTHCHECK --interval=30s --timeout=5s CMD ruby -rnet/http -rjson -e 'u=URI("http://127.0.0.1:9292/health"); r=Net::HTTP::Get.new(u); r["Host"]=URI(JSON.parse(File.read(ENV.fetch("CONFIG_FILE"))).fetch("publicUrl")).host; exit(Net::HTTP.start(u.host,u.port){|h|h.request(r)}.code == "200" ? 0 : 1)'
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
