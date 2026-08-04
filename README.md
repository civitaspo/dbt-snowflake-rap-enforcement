# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml)
[![Lint](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A dbt package for Snowflake that:

1. **Applies row access policies (RAP)** to models, including tables that already exist without a policy.
2. **Keeps RAP-side control** over whether downstream models may reference RAP-protected models (and under what conditions).

Adapter-independent reference authorization belongs with [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models). This package owns Snowflake-specific RAP application and the RAP metadata contract that those checks can consume.

## Status

Repository foundation and CI/release scaffolding are in place. Package macros and RAP apply logic will land in follow-up pull requests.

## Installation

Once a release tag exists:

```yaml
packages:
  - git: "https://github.com/civitaspo/dbt-snowflake-rap-enforcement.git"
    revision: v0.1.0
```

## Development

```bash
mise install --locked
mise run lint
mise run test
```

## Documentation

- [Contributing](CONTRIBUTING.md)
- [Securefix / CI automation](docs/securefix.md)
- [Releasing](docs/releasing.md)
- [Security](SECURITY.md)

## License

MIT License. See [LICENSE](LICENSE).
