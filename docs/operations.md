# Operating one instance

## Container releases

Release Please maintains a release pull request from conventional commits on
`main`; merging that pull request creates the GitHub release and tag. The first
release is configured as `v0.1.0`. The release workflow explicitly dispatches
the container workflow for that tag because tags created with `GITHUB_TOKEN` do
not trigger ordinary tag-push workflows. Check the container workflow result
and its digest before deploying; a GitHub release alone does not prove the
image was published.
If dispatch or publishing fails, rerun the container workflow manually against
the existing release tag; do not create a new tag for the same release.

The repository must allow GitHub Actions to create pull requests. With the
default `GITHUB_TOKEN`, GitHub requires a maintainer to approve workflow runs
on an Actions-created release pull request. A GitHub App token can remove that
approval step if one is configured later.

A push of a release tag such as `v1.0.0` or `v1.0.0-rc.1` builds and
publishes `ghcr.io/damacus/release-mirror` for Linux amd64 and arm64. The
workflow publishes the version tag and `sha-<full source commit SHA>` and
reports the multi-platform manifest digest in its job summary after checking
both architectures. Pin deployments to `ghcr.io/damacus/release-mirror@sha256:...`
using that published digest; tags can move. Ordinary pushes, including
documentation-only changes, do not publish images.

Release tags must use `vMAJOR.MINOR.PATCH` with an optional prerelease made of
letters, digits, dots and hyphens. Build metadata such as `+build.1` is not
supported because container tags cannot contain `+`. Unsupported tags that
begin with `v` fail before publishing.

GitHub creates a new container package private by default. After the first
publication, an owner must make the package public and verify anonymous pulls.
No image digest exists until a release has actually been published.

## Deployment boundary

Run one Puma process with one mounted SQLite directory. Put an HTTPS reverse proxy in front, configure `publicUrl` to the exact external origin, and expose the container only to that proxy. Mount an operator-owned JSON config read-only and inject secrets through your deployment's secret manager. The application has no installation-specific hostname or provider requirement.

The reverse proxy must forward the configured public host in the HTTP Host header. Client-supplied Forwarded and X-Forwarded-Host headers must be stripped or overwritten at the proxy.

Do not enable request-body, Authorization-header, cookie or query-string logging in the proxy, app server, identity client or error collector. OAuth callback queries contain short-lived codes and state. App responses and configured diagnostics are deliberately generic. Provider endpoints must use HTTPS; workload JWKS and human introspection endpoints come exclusively from operator configuration. The browser client discovers endpoints only from its configured issuer.

Use request-size limits (1 MiB), connection/read timeouts and normal traffic controls at the proxy as well as in the app. Public directories and tag lists are intentionally discoverable. No private information belongs in aliases, tag strings, digests or platforms.

## Identity setup before real publication

1. Register the browser OIDC application with authorization-code flow, S256 PKCE and the exact callback URL. Configure its signing algorithm. Set a strong random session encryption secret (at least 64 bytes) and client secret in environment variables.
2. Register the human API resource for Basic-authenticated introspection. The chosen token must introspect as an active Bearer access token for the catalogue audience, with issuer, subject and expiry. Do not use a browser ID token.
3. Set the bootstrap human issuer and exact user ID before first login. Verify that a different person is read-only. There is no first-login bootstrap.
4. Verify the deployed Forgejo/runner versions and actual workload token claims. Current Forgejo documents the workload issuer `/api/actions` and immutable `repository_id`. Pin the configured issuer, audience, key endpoint, type, algorithm and maximum token lifetime to the actual installation.
5. Create the public service alias as a global administrator. Grant `publish` for that service to the immutable repository ID. The owner intentionally accepts **any accepted build identity for that repository**, including pull-request builds; do not silently introduce a main/release-only condition. Forgejo controls which job/event identities it issues, including fork restrictions.
6. Verify browser sign-in, access-token introspection, successful workload publication and rejection from another repository. Local fixtures do not establish real deployment compatibility.

Authentication is not administration. Human global administrators manage the catalogue and grants. Workload publishers can add or update releases only in their assigned service; they cannot delete or manage permissions. Previous granular and scoped administrator grants no longer authorise operations and must be replaced deliberately. Existing human global administrator grants remain valid. Revocation is evaluated per request, even when a browser session remains authenticated.

## Sessions and keys

Browser sessions use encrypted authenticated cookies, HttpOnly, SameSite=Lax, Secure over production HTTPS, and a one-hour authentication lifetime. Login attempts expire after five minutes; state and nonce are consumed, callback overrides are rejected, and all browser mutations require matching CSRF values. Sign-out overwrites the browser session. A copied older cookie remains usable until its authentication expiry unless the session secret rotates; do not claim server-side per-session revocation. Permission revocation remains immediate.

Workload keys cache for at most 60 seconds. New signing keys may be rejected until that cache expires. Old keys can remain accepted for that window if a valid unexpired token otherwise passes validation. Bound token lifetime and plan rotations accordingly. Introspection is performed for every human API call and fails closed when unavailable. Invalid issuer credentials never trigger request-directed discovery or JWKS fetches.

## Backup and restore

Use SQLite's online backup facility or `VACUUM INTO` to create a consistent backup. Do not copy only the main database file while a WAL-mode database is running: the latest committed data may be in its WAL. Protect backups like other system state because the database also contains private grants and immutable-tag policy.

For example, from an operator script using the application dependencies:

```ruby
require_relative 'lib/release_mirror/store'
store = ReleaseMirror::Store.new('/data/catalogue.sqlite3')
store.db.run("VACUUM INTO '/data/backup.sqlite3'")
```

Use an operator-controlled backup destination that does not already exist. Copy that completed backup to normal backup storage according to your existing policy. No arbitrary retention period or backup-erasure scheme is imposed here.

To restore, stop the service, preserve the current files if needed, replace the database with a compatible consistent backup, remove stale `-wal`/`-shm` companions only while stopped, preserve UID/GID 10001 ownership, then start the same compatible application version and verify the public export and grants. A restored backup intentionally restores the entire catalogue as it existed then, including entries deleted afterwards. This is expected behaviour.

Public JSON export/import is a language-neutral metadata transfer, not a full operational backup: it excludes identity grants and private immutability flags. Import merges atomically using normal publisher or administrator rights; creating a service requires a global administrator. New entries preserve imported timestamps; existing timestamps are server-managed. Duplicate aliases/tags, mismatched service names, invalid timestamps or unknown fields reject the entire document. Requests exceeding 1 MiB must be split into independently reviewed imports; atomicity applies per request.

## Deletion and caches

Deleting a release removes its live row. Deleting a service removes that alias, its live releases and its scoped grants. Neither action contacts or deletes a private registry image. There are no public tombstones, stored release-body audit records or restore/unyank endpoints.

JSON catalogue reads send `public, max-age=0, must-revalidate` and never issue session cookies. Browser pages and authentication responses use `no-store`. An intermediary must revalidate before reusing catalogue data. Previously fetched, archived or copied public information cannot be recalled, and deletion does not regain privacy for it.

## Capacity and readiness

SQLite WAL mode and a five-second busy timeout support one modest instance. Directory/release responses are currently unpaginated. Monitor latency, database size and write contention before adopting a larger workload; do not run multiple replicas against this volume. No benchmark or production capacity claim is made.

Iterate in Ruby, review actual operational evidence and keep the HTTP contract portable. A Rust or Go implementation would need to pass the same acceptance suite and preserve export/import semantics. No rewrite is scheduled automatically.
