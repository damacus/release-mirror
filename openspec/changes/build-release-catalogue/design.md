# Design

## Context

The application repository is empty. See proposal.md for motivation and the two delta specs for the agreed behaviour. The public repository contains only reusable software and synthetic examples.

## Goals / Non-Goals

**Goals:** one portable process, a mounted SQLite data directory, a working browser dashboard, OIDC from the first implementation and replaceable HTTP/data contracts.

**Non-Goals:** registry synchronisation, image inspection, deployment, automatic releases, source publication or a language rewrite.

## Decisions

- Use Ruby 4.0.9, Sinatra, Sequel/sqlite3, Puma, ruby-jwt and OmniAuth OpenID Connect. Ruby keeps iteration small; SQLite avoids operating a database service for a single instance. Use locked maintained releases and Minitest/Rack::Test for behavioural tests. Runtime and CI action versions were refreshed on 9 November 2026 following the owner's security review.
- Keep validation, persistence, authorisation, token verification and HTTP/UI handling in separate small modules. Use parameterised database queries and transactions for multi-tag publication and import. No raw references enter the persistence interface.
- A release input has actual `tags`, a digest and platform descriptors; optional `reference` is parsed then discarded. An explicit immutable flag is private policy state supplied by the producer; default tags can move. No inferred immutability or synthetic tag is introduced.
- Represent identity as issuer plus subject for humans, issuer plus immutable repository claim for workloads. Trusted workload issuers configure an audience, JWKS URL, algorithm allowlist and repository claim. Grants are server-side and can apply globally or to one existing service. Administration is independent from write capabilities.
- Validate Forgejo workload JWTs using pinned issuer/audience and configured JWKS fetched only from administrator configuration. Require expiry, issued-at and subject; validate not-before and bounded lifetime. Do not filter branches or event names. Deployers verify the immutable repository claim and runner compatibility before enabling a real repository.
- Use Zitadel introspection for human API access tokens, supporting JWT and opaque access tokens without treating ID tokens as access tokens. Configure its endpoint and API client credentials explicitly, validate active status, issuer, audience, expiry and subject, and fail closed on upstream errors. Use TLS, bounded responses/timeouts and no redirects.
- Use OmniAuth authorization-code login with required state, nonce and S256 PKCE. Store only issuer/subject and authentication time in the application session, never the auth hash, tokens or profile. Require explicit bootstrap issuer/subject. All browser mutations use same-session CSRF tokens; cookies are HttpOnly, SameSite=Lax and Secure in production with bounded expiry.
- Keep publication time fixed and update time current on actual changes. SQLite uniqueness on service/tag and transactional permission checks prevent duplicate or partial writes. Deletion removes live rows, no tombstones or retained bodies. Cache-Control requires revalidation; prior public copies cannot be recalled.
- JSON export contains only public records plus a schema version. Import validates the whole document before an atomic merge and applies normal add/edit rights. Operator backups include the database and permission state; restore intentionally restores deleted entries from that snapshot.
- Renovate uses a custom datasource and regex manager capturing version and digest; disable Docker management for the example private package. Test against Renovate itself, including moving-tag digest updates. Keep private registry names exclusively in consumer-side synthetic examples.

## Risks / Trade-offs

- Authorised writers can encode information in allowed public strings → label public fields plainly; no claim of exfiltration prevention.
- Trusted repository builds include accepted PR identities → document the intentional trust and verify actual Forgejo claims before deployment.
- SQLite has one writer and one instance → use WAL/busy timeout and a mounted local volume; no multi-instance claim.
- Identity-provider outages prevent writes/login → fail closed while public reads continue.
- Deleted public data may survive caches/backups → revalidation and explicit restore semantics, without backup erasure or arbitrary retention promises.
- Local token fixtures prove validation rules, not a live Forgejo/Zitadel installation → keep real end-to-end identity acceptance as a separately reported deployment gate.

## Migration Plan

Create the initial schema on an empty mounted directory. Validate portable export/import and container restart persistence. Production rollout requires separate authorisation and verified provider configuration. Rollback uses the previous image plus a compatible database backup; restoring a backup restores its complete historical state.
