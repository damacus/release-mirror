# Proposal

## Why

Hosted dependency updaters need public container release metadata without access to private registries or source. A reusable catalogue can expose deliberately public aliases, actual upstream tags and image digests while keeping private image locations in consumer configuration.

## What Changes

- Add a Ruby/Sinatra service with SQLite persistence, anonymous JSON reads and a browser dashboard in the first version.
- Mirror actual upstream tags exactly. Producers choose when to submit successful builds; the catalogue introduces no versions, build numbers, classifications, aliases or retention policy.
- Accept only bounded, validated release fields, discarding private portions of optional image references before persistence or diagnostics.
- Authenticate workload publishing through trusted OIDC issuers and humans through OIDC login or validated API access tokens. Apply explicit global or service grants with separate add, edit, delete and administration permissions.
- Delete release entries from the live catalogue without tombstones or release-body history. Normal backup restoration restores the prior catalogue state.
- Provide a language-neutral HTTP/OpenAPI contract, import/export format, executable acceptance tests, portable container, publisher example and demonstrated Renovate version/digest integration.

## Capabilities

### New Capabilities

- `catalogue`: validated public release metadata, tag updates, persistence, deletion, portable data and consumer contract.
- `identity-access`: workload and human authentication, explicit permissions and secure browser administration.

### Modified Capabilities

None: the repository is empty.

## Impact

Introduces the application, dependency lock, tests and deployment examples. No production deployment, live identity-provider configuration, registry deletion or infrastructure changes are included. Public examples contain synthetic data only. A later language change must preserve the executable contract; no rewrite or calendar-based production-readiness promise is part of this change.
