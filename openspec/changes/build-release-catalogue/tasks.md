# Tasks

## 1. Core catalogue

- [x] 1.1 Establish Ruby dependencies and runnable test task; verify installation and a smoke request.
- [x] 1.2 Implement bounded allowlist validation and exact-tag/reference parsing; verify rejection and secrecy tests.
- [x] 1.3 Implement SQLite catalogue, immutable/moving tags and complete deletion; verify transactions, restart persistence and deletion tests.
- [x] 1.4 Implement explicit grants and capability checks; verify global, scoped, restricted and read-only matrices.

## 2. Identity and HTTP

- [x] 2.1 Implement trusted workload JWT verification and human access-token introspection; verify signed fixtures and rejection paths.
- [x] 2.2 Implement anonymous/public and protected mutation HTTP endpoints with OpenAPI and import/export; verify executable contract and atomic import tests.
- [x] 2.3 Implement human OIDC login and secure browser sessions; verify state, nonce, PKCE, CSRF, expiry and bootstrap tests.

## 3. Dashboard and integrations

- [x] 3.1 Implement responsive public browsing and authorised catalogue/grant forms; verify browser journeys and escaped values.
- [x] 3.2 Add synthetic publisher and Renovate consumer examples; demonstrate actual Renovate version and moving-tag digest updates with no private Docker datasource requests.
- [x] 3.3 Add portable container, CI and operating documentation; verify container startup, mounted persistence and backup/restore semantics.

## 4. Acceptance

- [x] 4.1 Run complete behavioural/security/contract checks and inspect repository for unintended private data; record actual results and remaining deployment gates.

## Workflow follow-up

- Publish reviewed application source only within authorised repository scope; do not merge or deploy without separate authorisation.
- Verify real Forgejo runner/token claims and Zitadel login/introspection before a separately authorised production deployment.
