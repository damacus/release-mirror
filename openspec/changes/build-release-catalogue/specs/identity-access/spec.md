## Purpose

Authenticate build publishers and human operators while granting only explicit permissions over public catalogue data.

## ADDED Requirements

### Requirement: Trusted workload identities
The service SHALL validate workload token signature, configured issuer, audience, lifetime and identity against configured trusted keys. Repository identity SHALL map server-side to explicit service permissions; issuer authentication alone SHALL grant no write access. Request-supplied discovery/key locations SHALL NOT be used.

#### Scenario: Approved repository build
- **WHEN** any authenticated build in an approved repository presents an accepted identity token, including a pull-request build
- **THEN** its configured service permissions apply without a branch or release-job restriction

#### Scenario: Other repository denied
- **WHEN** a valid token identifies an unapproved repository
- **THEN** publishing is forbidden

### Requirement: Human identities and bootstrap
Human login SHALL use OIDC. Human API calls SHALL use validated access tokens, including supported opaque tokens, rather than accepting ID tokens as API credentials. The first administrator SHALL be an explicitly configured issuer and subject, never the first login.

#### Scenario: New human is read-only
- **WHEN** an authenticated person has no grants and is not the configured bootstrap identity
- **THEN** they can browse but cannot mutate data or permissions

### Requirement: Explicit capabilities
Grants SHALL support global write, service-scoped full editing and service-scoped restricted add/edit/delete capabilities, with separate administration. Global add permission SHALL permit alias creation; scoped grants SHALL NOT implicitly create or access other services.

#### Scenario: Add-only writer
- **WHEN** a service add-only writer attempts to edit or delete an existing tag
- **THEN** access is forbidden

#### Scenario: Scoped alias creation denied
- **WHEN** a scoped writer attempts to create another service alias
- **THEN** access is forbidden

### Requirement: Secure dashboard administration
The dashboard SHALL provide anonymous browsing, login and authorised service, release and permission administration. Login SHALL validate state and nonce with PKCE; mutations SHALL enforce CSRF protection. Sessions SHALL expire and use secure cookies, and public values SHALL be escaped.

#### Scenario: Forged browser mutation
- **WHEN** an authenticated browser posts without a matching CSRF token
- **THEN** the mutation is rejected

### Requirement: Diagnostic secrecy
Tokens, full token payloads, raw references, request bodies and rejected field contents SHALL NOT be retained in diagnostics or exposed in responses. Allowed public strings SHALL be clearly labelled as public; validation SHALL NOT be described as preventing deliberate disclosure by authorised writers.

#### Scenario: Invalid credential
- **WHEN** token verification fails
- **THEN** the response is generic and logs contain no credential or claims
