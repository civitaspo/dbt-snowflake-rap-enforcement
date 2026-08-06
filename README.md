# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml)
[![Lint](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Snowflake-oriented dbt package that:

1. **Applies a row access policy (RAP)** to models and snapshots, including relations that already exist without a policy (`on-run-end` bulk `ALTER`).
2. **Enforces RAP-side downstream policy** declared on protected models (`on-run-start` graph lint).

Snowflake allows **one RAP per relation**. This package always converges a target to a single `config.row_access_policy`. Compose multiple rules inside one policy body (warehouse / Terraform); do not try to attach multiple RAPs.

Adapter-independent reference authorization belongs with [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) (`meta.authorize`). This package does **not** depend on it; install both and wire both hooks when you need both behaviors. See [docs/boundaries.md](docs/boundaries.md).

## Installation

```yaml
packages:
  - git: "https://github.com/civitaspo/dbt-snowflake-rap-enforcement.git"
    revision: v0.1.0
```

```bash
dbt deps
```

## Quick start

```yaml
# dbt_project.yml (root project)
on-run-start:
  - "{{ dbt_snowflake_rap_enforcement.check_downstream_rap() }}"

on-run-end:
  - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"

vars:
  dbt_snowflake_rap_enforcement:
    enforce_downstream: false  # warn first; set true to fail
    exclude_resource_types: ["test", "analysis"]
    require_materializations:
      - table
      - incremental
      - snapshot
      - dynamic_table
    enforce:
      selected_only: false
      unknown_materialization: error
    apply:
      enabled: true
      dry_run: false
      selected_only: false
      commands: [run, build, run-operation]
```

Protect a model with the built-in Snowflake config (CREATE-time path) and optional package meta:

```sql
{{
  config(
    materialized='table',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
        'require_downstream': true,
        'enforce_policy': 'inherit',
        'allow_without_rap': [
          {'resource_type': 'model', 'name': 'mart_public_counts'}
        ]
      }
    }
  )
}}

select ...
```

Folder defaults can use `+meta.row_access_policy_enforcement` in `dbt_project.yml`.

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream primary FQN must equal this node's primary FQN |
| `any` | Downstream must declare any RAP |
| `explicit` | Downstream primary FQN must equal `required_policy` (single FQN string) |

Example `explicit`:

```yaml
meta:
  row_access_policy_enforcement:
    enforce_policy: explicit
    required_policy: system.row_access_policies.tenant_policy
```

Views and ephemerals without a RAP are not required to declare one; lint walks through them to physical terminals. A RAP-bearing node is checked against the ancestor requirement, then becomes a trust boundary (further descendants are governed by that node's own `require_downstream`, which defaults to `true` when a RAP is present).

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Collects model/snapshot targets with a primary `row_access_policy`
2. Fetches existing relations with one `information_schema.tables` query per database (includes `is_dynamic`)
3. Fetches attachments with relation-scoped `policy_references` (so stale FQNs are visible)
4. Plans in memory and runs only needed `ALTER ... ADD` / `DROP ..., ADD` (or `DROP ALL, ADD`) to converge to the single desired RAP
5. Skips missing relations with a named warning
6. Runs only for commands in `apply.commands` (default: `run`, `build`, `run-operation`)
7. Fails the run on metadata/ALTER errors unless `apply.dry_run` / `apply.enabled: false`

Manual: `dbt run-operation apply_row_access_policies`

Quoted/case-sensitive Snowflake identifiers are not supported; Information Schema lookups use uppercase unquoted database names.

### Privileges

The dbt role needs ownership of target objects (or `APPLYROWACCESSPOLICY`) and `APPLY` on the policies. Policies must already exist.

## Development

```bash
mise install --locked
uv sync
mise run lint
mise run test
```

## Documentation

- [Package boundaries](docs/boundaries.md)
- [Contributing](CONTRIBUTING.md)
- [Securefix / CI automation](docs/securefix.md)
- [Releasing](docs/releasing.md)
- [Security](SECURITY.md)

## License

MIT License. See [LICENSE](LICENSE).
