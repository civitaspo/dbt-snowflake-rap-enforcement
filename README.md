# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml)
[![Lint](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Snowflake-oriented dbt package that:

1. **Applies a row access policy** to models and snapshots, including relations that already exist without a policy (`on-run-end` bulk `ALTER`).
2. **Checks downstream row access policy declarations** on protected models (`on-run-start` graph lint).

Snowflake allows **one row access policy per relation**. This package always converges a target to a single `config.row_access_policy`. Compose multiple rules inside one policy body (warehouse / Terraform); do not try to attach multiple policies.

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
  - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policy() }}"

on-run-end:
  - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"

vars:
  row_access_policy_enforcement:
    # Downstream check (check_downstream_row_access_policy)
    fail_on_violation: false  # false = warn; true = fail the run
    exclude_resource_types: ["test", "analysis"]
    required_materializations:
      - table
      - incremental
      - snapshot
      - dynamic_table
    unknown_materialization: error
    selected_only: false  # shared by check + apply

    # Warehouse ALTER (apply_row_access_policies)
    apply_enforcement:
      enabled: true
      dry_run: false
      commands: [run, build, run-operation]
```

### Vars reference

| Option | Hook | Meaning |
|--------|------|---------|
| `fail_on_violation` | check | When violations exist: `true` fails the run, `false` logs and continues |
| `required_materializations` | check | Materializations treated as physical terminals that must satisfy policy |
| `exclude_resource_types` | check | Resource types ignored by the check |
| `unknown_materialization` | check | `error` or `skip` for non-passthrough / non-required materializations |
| `selected_only` | check + apply | When `true`, only selected resources are checked/applied; empty selection ⇒ no targets |
| `apply_enforcement.enabled` | apply | When `false`, skip all warehouse `ALTER`s |
| `apply_enforcement.dry_run` | apply | Log planned `ALTER`s without executing |
| `apply_enforcement.commands` | apply | dbt commands allowed to run apply (`flags.WHICH`) |

`fail_on_violation` and `apply_enforcement.enabled` are **not** the same: the first only controls check severity; the second only controls whether DDL runs.

Protect a model with the built-in Snowflake config (CREATE-time path) and optional package meta:

```sql
{{
  config(
    materialized='table',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
        'enforce_downstream': true,
        'enforce_policy': 'inherit',
        'allow_without_row_access_policy': [
          {'resource_type': 'model', 'name': 'mart_public_counts'}
        ]
      }
    }
  )
}}

select ...
```

Folder defaults can use `+meta.row_access_policy_enforcement` in `dbt_project.yml`.

### Meta reference

| Option | Meaning |
|--------|---------|
| `enforce_downstream` | When this node declares a row access policy, require downstream terminals to satisfy `enforce_policy` (default `true`) |
| `enforce_policy` | `inherit` \| `any` \| `explicit` |
| `required_policy` | Single policy FQN required when `enforce_policy` is `explicit` |
| `allow_without_row_access_policy` | Exemption rules for downstream nodes |

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream primary FQN must equal this node's primary FQN |
| `any` | Downstream must declare any row access policy |
| `explicit` | Downstream primary FQN must equal `required_policy` |

Views and ephemerals without a row access policy are not required to declare one; the check walks through them to physical terminals. A policy-bearing node is checked against the ancestor requirement, then becomes a trust boundary (further descendants are governed by that node's own `enforce_downstream`, which defaults to `true` when a policy is present).

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Collects model/snapshot targets with a primary `row_access_policy`
2. Fetches existing relations with one `information_schema.tables` query per database (includes `is_dynamic`)
3. Fetches attachments with relation-scoped `policy_references` (so stale FQNs are visible)
4. Plans in memory and runs only needed `ALTER ... ADD` / `DROP ..., ADD` (or `DROP ALL, ADD`) to converge to the single desired policy
5. Skips missing relations with a named warning
6. Runs only for commands in `apply_enforcement.commands`
7. Fails the run on metadata/ALTER errors unless `dry_run` / `enabled: false`

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
