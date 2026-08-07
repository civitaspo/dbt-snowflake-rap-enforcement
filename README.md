# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml)
[![Lint](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Snowflake-oriented dbt package that:

1. **Applies a row access policy** to selected models/snapshots (`on-run-end` bulk `ALTER`).
2. **Checks downstream row access policy declarations** on the full graph (`on-run-start`).

Snowflake allows **one row access policy per relation**. Compose multiple rules inside one policy body (warehouse / Terraform).

Adapter-independent reference authorization belongs with [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) (`meta.authorize`). See [docs/boundaries.md](docs/boundaries.md).

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
    # Terminals that must satisfy enforce_policy
    required_materializations:
      - table
      - incremental
      - snapshot
      - dynamic_table
    # Passthrough (declaration optional; walk continues)
    optional_materializations:
      - view
      - ephemeral
    exclude_resource_types: ["test", "analysis"]
    # Drop/replace attached policy when it differs from config (default true)
    apply_authoritatively: true
```

Materializations in neither `required_materializations` nor `optional_materializations` are always treated as check violations (fail closed). Put passthrough types in `optional_materializations` (e.g. add `materialized_view` there if you want to walk through them).

### Vars reference

| Option | Hook | Meaning |
|--------|------|---------|
| `required_materializations` | check | Terminals that must satisfy the upstream `enforce_policy` |
| `optional_materializations` | check | Passthrough nodes (declaration optional; walk continues) |
| `exclude_resource_types` | check | Resource types ignored by the check |
| `apply_authoritatively` | apply | `true` (default): drop/replace attached policy when it differs from config. `false`: only `ADD` when nothing is attached; leave mismatches |

Wiring the hooks is the on/off switch:

- Check is wired ⇒ violations **fail** the run (full graph).
- Apply is wired ⇒ on `run` / `build` / `run-operation`, apply to **selected** models/snapshots that declare `row_access_policy`.

Protect a model:

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

### Meta reference

| Option | Meaning |
|--------|---------|
| `enforce_downstream` | When this node declares a policy, enforce downstream terminals (default `true`) |
| `enforce_policy` | `inherit` \| `any` \| `explicit` |
| `required_policy` | Single policy FQN when `enforce_policy` is `explicit` |
| `allow_without_row_access_policy` | Exemption rules for downstream nodes |

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream primary FQN must equal this node's primary FQN |
| `any` | Downstream must declare any row access policy |
| `explicit` | Downstream primary FQN must equal `required_policy` |

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Targets = current selection ∩ models/snapshots with `row_access_policy`
2. Bulk-fetch relations (`information_schema.tables`, including `is_dynamic`) and attachments (relation-scoped `policy_references`)
3. Plan and run `ALTER ... ADD` / `DROP ..., ADD` / `DROP ALL, ADD` when `apply_authoritatively=true`
4. Skip missing relations with a named warning
5. Commands: `run`, `build`, `run-operation` only

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
