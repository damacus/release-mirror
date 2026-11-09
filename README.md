# Release Mirror

A public metadata catalogue for private container images. Publish actual upstream tags, OCI image/index digests and platforms; let dependency updaters read them anonymously. Source, image contents and registry credentials stay private.

The catalogue does not create versions or tags, decide which builds are releases, fetch images or delete upstream registry objects. The producer decides when to publish after a successful build and push. An accepted build identity for an approved repository can publish regardless of branch or event, including accepted pull-request builds.

## Usage documentation

The [Middleman documentation site](docs/site/source/index.html.md.erb) covers browsing, administration, publishing and Renovate setup. See [the documentation contributor guide](docs/site/source/contributing.html.md.erb) to preview and build it locally. A separate documentation workflow builds and publishes to GitHub Pages after repository Pages setup; application verification skips documentation-only changes.

## Run locally

Requires Ruby 4.0.9 and Bundler, or Docker. With mise and Fish:

```fish
mise trust
mise install
mise exec -- ruby -S bundle install
cp config/local.example.json config/local.json
set -gx SESSION_SECRET (mise exec -- ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
mise run serve
```

Open <http://localhost:9292>. This local configuration permits public browsing only. Configure trusted identity providers and an explicit bootstrap administrator to enable writes. No shared-token or unauthenticated write mode exists.

For a container, set `databasePath` to `/data/catalogue.sqlite3` in the local config, then run `docker compose up --build`. The image runs as UID/GID 10001 with a mounted data directory; Compose binds only to loopback. Serve production traffic through an HTTPS reverse proxy. See [operations](docs/operations.md).

## Configure identities

Copy [config/example.json](config/example.json) to an untracked config file. Set `CONFIG_FILE` to that file. Secrets are named environment variables, never values in the JSON examples.

- **Workloads:** configure exact issuer, catalogue audience, trusted JWKS endpoint, signing algorithms, expected token type and repository identity claim. Forgejo uses `repository_id`, an immutable repository identifier. Grant that ID permissions on an existing service. Issuer authentication alone gives no permissions. The service does not apply a branch/release-job restriction.
- **Human browser login:** configure an OIDC client, issuer and exact callback `<publicUrl>/auth/oidc/callback`. Login uses authorization code, state, nonce and S256 PKCE. Only issuer, subject and authentication time enter the encrypted session. New users are read-only.
- **Human API:** configure a Zitadel API client with Basic-authenticated introspection. Both opaque and JWT access tokens are introspected. The response must confirm an active Bearer access token, exact issuer, intended audience, subject and unexpired lifetime. ID tokens are not API credentials. Other issuers can be used if they implement this response contract.
- **Bootstrap:** explicitly set `bootstrap` to a human issuer and user ID. There is no first-login-wins behaviour. This configured identity retains administration until configuration changes; it is not a removable database grant.

There are two roles: a human global `admin` can manage services, releases and grants; a workload `publish` grant allows a repository to add or update releases for one existing service. Publishers cannot delete releases, create services or manage grants. Existing granular grants must be replaced with the appropriate role. Grants apply immediately to subsequent requests.

The permission dashboard accepts human subjects or workload repository IDs. Only trusted issuer configuration determines which credentials can authenticate; creating a grant cannot add a trusted issuer.

## Public data contract

Every alias and published tag is discoverable by design. Public release JSON includes only `service`, `version` (the actual tag), `digest`, `platforms`, `publishedAt` and `updatedAt`. The Renovate view exposes `version`, `digest` and `releaseTimestamp`.

- [OpenAPI 3.1](docs/openapi.yaml): endpoints, schemas, status codes and authentication.
- [Publication example](examples/publication.json): multiple real upstream tags for one image digest and platform set.
- [Reusable Forgejo action](action.yml) and [job fragment](examples/forgejo-job.yaml): supply actual tags, digest and OCI platform objects after a successful push. The action creates the JSON and requests workload identity using the [standard-library Ruby publisher](examples/publish.rb).
- [Renovate consumer](examples/renovate/renovate.json) and [synthetic image references](examples/renovate/images.yaml): custom datasource and regex manager; private paths remain in the consumer.

Tag grammar follows distribution/reference: 1–128 ASCII characters, starting with a letter, digit or underscore, followed by letters, digits, underscores, periods or hyphens. Supported content digest algorithms are SHA-256/384/512 with the exact lowercase hex length. A Git SHA is not an image digest. Platform components are bounded ASCII tokens; optional OCI `variant`, `os.version` and `os.features` are supported. Unknown fields, annotations, source URLs, notes and raw webhooks are rejected. Requests are limited to 1 MiB and nested JSON to 16 levels.

An optional full `reference` accepts `name[:tag][@digest]`, including registry ports, nested names and bracketed IPv6 registries. It must include a tag or digest; explicit fields must agree. No URL scheme or credentials are accepted. The registry/repository portion is discarded before the persistence interface, never echoed. No submitted URL is fetched. The server uses configured identity-provider endpoints only.

Tags move unless the producer explicitly supplies `immutable: true` for actual immutable upstream tags. That private policy flag prevents later image/platform changes or removal of immutability; it creates no new tag. Public export excludes this policy and grants. Use a normal database backup to preserve those as well.

Allowed public strings can intentionally carry information. Validation is not an exfiltration guarantee against an authorised publisher. Do not submit information you would not publish on an anonymous website.

## Renovate integration

The example restricts management to `custom.regex`, so the private packages do not trigger duplicate Docker datasource lookups. When adding it to an existing consumer, preserve other desired managers and exclude these exact private packages from Docker managers separately. Replace only the catalogue URL and synthetic consumer references with your own configuration.

Choose consumer versioning that fits the real upstream tags. The semantic example uses semver. For the upstream `latest` example, a regex versioning rule treats only that literal tag as the same version so a changed digest can update it. The catalogue never invents a moving alias or translates tags into synthetic versions.

The executable integration test runs Renovate 44.222.5's actual regex extraction, HTTP custom datasource lookup and update selection. It checks a version-plus-digest update and a digest-only moving-tag update. This is local engine evidence; hosted installation remains an acceptance step before production.

## Verify

```fish
mise run test
```

This runs request, persistence, permission, JWT, introspection and OIDC browser tests. Identity-provider traffic is controlled in tests; no live accounts or proprietary images are needed.

Run `bundle exec srb tc` to check Sorbet types. Typing is gradual: validation,
configuration, authentication and the browser OIDC adapter are checked; the
Sinatra routes and persistence still need typed coverage. Regenerate dependency
interfaces with `bin/tapioca gem` when changing gems.

For language-neutral HTTP acceptance against the isolated synthetic server, run in one terminal:

```fish
set -gx FIXTURE_DIR /tmp/release-mirror-fixture
mise exec -- ruby -rbundler/setup test/support/preview.rb
```

Then in another terminal:

```fish
set -gx CONTRACT_TOKEN_FILE /tmp/release-mirror-fixture/token
mise exec -- ruby test/contract/acceptance.rb
npm install --prefix /tmp/release-mirror-renovate --ignore-scripts renovate@44.222.5
set -gx RENOVATE_ENTRY /tmp/release-mirror-renovate/node_modules/renovate/dist/renovate.js
node test/contract/renovate.mjs
docker build -t release-mirror:local .
mise exec -- ruby test/contract/container.rb
```

The HTTP test creates and removes `contract-fixture`; use an isolated catalogue only. The preview signs real synthetic workload JWTs but supplies fixture JWKS via an injected transport. It is never the production entrypoint. The Renovate test needs Node supported by the pinned Renovate package; it uses only a disposable local git index and does not publish branches or PRs. The container test creates and cleans its own named volume/container.

## Status and limits

This is a single-instance prototype. See [verification](docs/verification.md) for measured evidence and remaining acceptance gates. Production deployment, live Forgejo/Zitadel settings and proprietary image publication are outside this repository's implementation work. There is no promised production date or planned automatic rewrite.
