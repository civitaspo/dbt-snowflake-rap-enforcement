# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

## [0.4.1] - 2026-08-11


### Maintenance

- harden reusable workflow calls for status-check (#35)
- update dependency jdx/mise to v2026.8.4 (#34)
- grant nested reusable workflow permissions from callers (#33)
- collapse PR checks into status-check gate (#31)

## [0.4.0] - 2026-08-10


### Features

- switch license from MIT to Apache License 2.0 (#30)


### Maintenance

- lock file maintenance (#29)
- migrate Renovate config (#24)
- bump securefix-server reusables for job summary links (#27)

## [0.3.1] - 2026-08-09


### Documentation

- point releasing guide at shared client-releases spec (#25)


### Maintenance

- use securefix-server release workflow reusables (#23)

## [0.3.0] - 2026-08-08


### Bug Fixes

- read RAP columns from REF_ARG_COLUMN_NAMES and uppercase policy FQNs in ALTER DDL (#22)


### Features

- prefix package logs with (dbt-snowflake-rap-enforcement) (#20)

## [0.2.0] - 2026-08-08


### Bug Fixes

- update dependency dbt-duckdb to >=1.11,<1.12 (#12)


### Features

- remove enforce_downstream meta option (#14)


### Maintenance

- forbid CHANGELOG edits outside release/next (#19)
- generate releases with git-cliff (#18)
- harden release PR metadata sync (#17)
- sync release/next PR title and body from version file (#16)
- update dependency jdx/mise to v2026.8.3 (#15)
- update dependency aqua:astral-sh/uv to v0.12.3 (#11)

## [0.1.0] - 2026-08-07


### Bug Fixes

- update dependency dbt-snowflake to >=1.12,<1.13 (#10)
- update dependency dbt-core to >=1.12,<1.13 (#9)


### Features

- Snowflake RAP apply and downstream enforcement (#6)


### Maintenance

- allow cursoragent in Approve Request committers (#8)
- update dependency aqua:astral-sh/uv to v0.12.2 (#7)
- update dependency aqua:astral-sh/uv to v0.12.1 (#4)
- update dependency jdx/mise to v2026.8.2 (#3)
- add lint, test, approval, and CSM release workflows (#2)
- repository foundation (#1)
- bootstrap repository


