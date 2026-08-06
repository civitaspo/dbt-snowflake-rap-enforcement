# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/ci.yml)
[![Lint](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Snowflake-oriented dbt package that:

1. **Applies row access policies (RAP)** to models and snapshots, including relations that already exist without a policy (`on-run-end` bulk `ALTER`).
2. **Enforces RAP-side downstream policy** declared on protected models (`on-run-start` graph lint).

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
    apply:
      enabled: true
      dry_run: false
      selected_only: false
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
        'additional_row_access_policies': [
          'system.row_access_policies.other_policy on (org_id)'
        ],
        'allow_without_rap': [
          {'resource_type': 'model', 'name': 'mart_public_counts'}
        ]
      }
    }
  )
}}

select ...
```

`additional_row_access_policies` requires a primary `row_access_policy`. Folder defaults can use `+meta.row_access_policy_enforcement` in `dbt_project.yml`.

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream physical nodes must declare every FQN from the upstream primary + additional set |
| `any` | Downstream must declare any RAP |
| `explicit-one-of` | Downstream FQN set intersects `policies` (FQNs only) |
| `explicit-all` | Downstream FQN set contains every entry in `policies` |

Views and ephemerals are not required to declare RAP. Lint walks through RAP-less view/ephemeral chains to physical terminals, and stops when it hits a RAP-bearing node.

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Collects model/snapshot targets with RAP declarations
2. Fetches attachments with **one `policy_references` query per database** (distinct policies)
3. Fetches existing relations with **one `information_schema.tables` query per database** (schema list)
4. Diffs in memory and runs only needed `ALTER ... ADD` / `DROP ..., ADD`
5. Skips missing relations; warns on unmanaged extra policies (does not drop them)
6. Fails the run on metadata/ALTER errors unless `apply.dry_run` / `apply.enabled: false`

Manual: `dbt run-operation apply_row_access_policies`

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
