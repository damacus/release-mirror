# Verification record

Checked locally on 9 November 2026. These results describe the prototype, not a production deployment.

| Check | Evidence |
| --- | --- |
| OpenSpec | `openspec validate build-release-catalogue --strict` passes; proposal, design, two capability specs and tasks are present. |
| Application behaviour | `mise run test`: 24 tests, 201 assertions, no failures/errors/skips. |
| Workload authentication | Real RSA-signed JWT fixtures; signature, configured issuer/audience/type, missing claims, time bounds and repository mapping tested. Header-supplied key locations are ignored. Accepted PR-build and other-branch identities receive the same configured repository grant. |
| Human API access | Opaque and JWT access tokens pass controlled introspection; wrong issuer/audience/type, inactive and expired credentials are rejected. |
| Browser OIDC | Actual middleware code with controlled HTTPS provider responses: authorization code, state, nonce, S256 PKCE, rejected callback overrides/missing ID token/replay, login expiry, session expiry, read-only first login, explicit bootstrap and sign-out. |
| Browser administration | Request journeys create a service, publish/delete metadata and add escaped permission subjects. CSRF and cookie/API separation are checked. |
| Public JSON | Exact allowlist, unknown-field rejection, generic diagnostics and no session cookies on cacheable catalogue responses. |
| HTTP portability | Standalone HTTP acceptance passes against a real local Puma server using signed synthetic workload credentials; no application imports in the client. |
| Renovate | 44.222.5 performs actual regex extraction, HTTP custom datasource lookup and update selection: `v1.0.0` to `v1.1.0` with the new digest; unchanged upstream `latest` receives a digest-only update. Only custom datasource dependencies are extracted. |
| Container | Ruby 3.4.9 Linux image built locally. Disposable container/volume test passes under UID 10001, read-only root, dropped capabilities and no new privileges. Metadata survives restart; complete live deletion and intentional backup restoration are demonstrated. |
| Dashboard layout | Desktop catalogue and 390-pixel mobile service page visually inspected; mobile page has no horizontal overflow. |
| OpenAPI | 3.1 YAML parses; HTTP response field and behaviour assertions run independently of the Ruby implementation. |
| Public boundary scan | Gitleaks directory scan reports no leaks. Targeted inspection finds no real credentials, private source/registry names or local filesystem paths in project files. |

The local preview injects fixture JWKS through a test transport; the browser provider and introspection responses are controlled fixtures. No real identity token, private registry, private application source or image was used.

The dependency suite emits upstream URI deprecation warnings from the OIDC URL-validation dependency and two Rack test string warnings. They do not fail tests. The npm-based Renovate check uses its JavaScript RegExp fallback when optional native RE2 is absent; the expression uses the RE2-compatible subset, and hosted engine compatibility remains a real-installation check.

Before any separately authorised production rollout, verify the actual Forgejo server/runner versions, accepted repository claims, signing algorithm/type/lifetime, Zitadel browser login and API introspection audience. Then test the hosted Renovate consumer. Observe real workload latency, database size and contention before making capacity claims. CI is configured but local checks do not prove hosted CI has run.
