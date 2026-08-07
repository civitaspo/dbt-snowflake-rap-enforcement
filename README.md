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
  dbt_snowflake_rap_enforcement:
    # Walk through these without requiring a declaration (default)
    passthrough_materializations:
      - view
      - ephemeral
    exclude_resource_types: ["test", "analysis"]
    # Drop/replace attached policy when it differs from config (default true)
    apply_authoritatively: true
```

Downstream check walk:

- Materialization in `passthrough_materializations` → continue through the node (unless it declares its own policy, which becomes a trust boundary).
- Any other model/snapshot → terminal; must satisfy the upstream `enforce_policy`.
- An `allow_without_row_access_policy` match is also a trust boundary: the walk does not continue past that terminal.

### Vars reference

| Option | Hook | Meaning |
|--------|------|---------|
| `passthrough_materializations` | check | Materializations the graph walk passes through without requiring a policy declaration |
| `exclude_resource_types` | check | Resource types ignored by the check |
| `apply_authoritatively` | apply | `true` (default): drop/replace attached policy when it differs from config. `false`: only `ADD` when nothing is attached; leave mismatches |

Wiring the hooks is the on/off switch:

- Check is wired ⇒ violations **fail** any command that executes the hook (full graph).
- Apply is wired ⇒ on `run` / `build` / `snapshot` / `retry`, apply to **selected** models/snapshots that declare `row_access_policy`. On `run-operation`, apply to all eligible nodes in the project graph (dbt does not populate selection for that command).

Identifier assumption: **unquoted** Snowflake identifiers only (case-insensitive). Case-sensitive / `quote_identifiers` relations are not supported for apply/fetch.

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
          'mart_public_counts'
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
| `allow_without_row_access_policy` | Exempt downstream names (or regexes), or `'*'`. Matched against `name`, `package.name`, and `unique_id`. Bare names match across packages. Allowed terminals are trust boundaries (walk stops). |

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream primary FQN must equal this node's primary FQN |
| `any` | Downstream must declare any row access policy |
| `explicit` | Downstream primary FQN must equal `required_policy` |

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Targets = (`run`/`build`/`snapshot`/`retry`: current selection; `run-operation`: project graph) ∩ models/snapshots with `row_access_policy`
2. Fetch existing relations (`information_schema.tables`, including `is_dynamic`)
3. Fetch attachments only for relations that exist (relation-scoped `policy_references` with fully qualified `ref_entity_name`) — missing objects are skipped with a warning because `POLICY_REFERENCES` errors on absent names
4. Plan and run `ALTER ... ADD` / named `DROP ..., ADD` / (`DROP ALL` then `ADD`) when `apply_authoritatively=true`
5. Commands: `run`, `build`, `snapshot`, `retry`, `run-operation`

### Privileges

The dbt role needs ownership of target objects (or schema-level `APPLY ROW ACCESS POLICY`) and `APPLY` on the policies. Policies must already exist. `POLICY_REFERENCES` visibility is stricter than ALTER: lacking the right privileges can error or return no rows (planner may then attempt ADD).

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
