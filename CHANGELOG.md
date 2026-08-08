# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.2.0] - 2026-08-08

### Features

- remove enforce_downstream meta option (#14)

### Bug Fixes

- update dependency dbt-duckdb to >=1.11,<1.12 (#12)

### Removed

- `meta.row_access_policy_enforcement.enforce_downstream`. Models that declare a row access policy always participate in the downstream check; use `allow_without_row_access_policy: ["*"]` when no downstream terminal should fail.
- Legacy rename/removed-key guardrails for old vars and meta names (unknown keys are ignored).

### Maintenance

- harden release PR metadata sync (#17)
- sync release/next PR title and body from version file (#16)
- update dependency jdx/mise to v2026.8.3 (#15)
- update dependency aqua:astral-sh/uv to v0.12.3 (#11)

## [0.1.0] - 2026-08-07

### Features

- Snowflake RAP apply and downstream enforcement (#6)

### Bug Fixes

- update dependency dbt-snowflake to >=1.12,<1.13 (#10)
- update dependency dbt-core to >=1.12,<1.13 (#9)

### Maintenance

- allow cursoragent in Approve Request committers (#8)
- update dependency aqua:astral-sh/uv to v0.12.2 (#7)
- update dependency aqua:astral-sh/uv to v0.12.1 (#4)
- update dependency jdx/mise to v2026.8.2 (#3)
- add lint, test, approval, and CSM release workflows (#2)
- repository foundation (#1)
- bootstrap repository
