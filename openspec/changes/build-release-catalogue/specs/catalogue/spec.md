## Purpose

Expose deliberately public container metadata for dependency discovery while keeping private registries and source outside the catalogue.

## ADDED Requirements

### Requirement: Exact upstream tags
The catalogue SHALL store producer-submitted tags exactly and SHALL NOT generate versions, build numbers, release classes, retention schemes or main/canary aliases. Producers determine publication timing.

#### Scenario: Moving tag advances
- **WHEN** an authorised editor submits an existing moving tag with a new image digest
- **THEN** its current digest and update timestamp change while its publication timestamp stays fixed

#### Scenario: Immutable tag stays fixed
- **WHEN** a publisher marks an actual upstream tag immutable and later submits a different digest
- **THEN** the catalogue rejects the change atomically

### Requirement: Public allowlist
The catalogue SHALL publish only service alias, tag/version, OCI digest, publication/update timestamps and validated platform descriptors. It SHALL reject unknown fields and bounded-input violations without echoing rejected values. Aliases and tag histories SHALL be anonymously discoverable.

#### Scenario: Private reference is discarded
- **WHEN** a valid full container reference accompanies release metadata
- **THEN** only its tag and image digest can survive parsing and no registry/repository portion is stored, logged or returned

#### Scenario: Unexpected metadata rejected
- **WHEN** input includes annotations, labels, source information, logs, notes or arbitrary metadata
- **THEN** the request fails without recording or returning its body

### Requirement: Container grammar
Inputs SHALL validate container tags, OCI image or image-index digests and platform descriptors using explicit bounds and grammar. Git commit SHAs SHALL NOT qualify as image digests. The service SHALL NOT fetch caller URLs, accept image uploads or proxy registries.

#### Scenario: Git SHA rejected
- **WHEN** a bare Git SHA is supplied as an image digest
- **THEN** validation fails

### Requirement: Complete live deletion
Deletion SHALL remove the release entry from the live catalogue without public tombstones, release-body history or an unyank feature. It SHALL NOT delete upstream images. Anonymous responses SHALL require cache revalidation.

#### Scenario: Deleted release disappears
- **WHEN** an authorised deleter removes a tag
- **THEN** subsequent revalidated catalogue reads exclude it and direct reads return not found

#### Scenario: Backup restoration
- **WHEN** an operator restores a normal earlier database backup
- **THEN** the earlier catalogue state returns, including entries deleted after that backup

### Requirement: Portable contract
The project SHALL provide a language-neutral OpenAPI contract, versioned JSON import/export and executable HTTP acceptance tests. Renovate integration SHALL demonstrate both version and digest updates without Docker datasource lookups for these packages.

#### Scenario: Consumer updates
- **WHEN** the example consumer reads a newer tag or changed digest for its current tag
- **THEN** Renovate proposes the corresponding change while private registry paths remain in consumer configuration
