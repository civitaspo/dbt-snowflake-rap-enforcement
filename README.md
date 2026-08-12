# dbt-snowflake-rap-enforcement

[![CI](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/pull_request.yml/badge.svg)](https://github.com/civitaspo/dbt-snowflake-rap-enforcement/actions/workflows/pull_request.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A Snowflake-oriented dbt package that:

1. **Applies a row access policy** to selected models/snapshots (`on-run-end` bulk `ALTER`).
2. **Checks downstream row access policy declarations** on the full graph (`on-run-start`).

Snowflake allows **one row access policy per relation**. This package attaches at most one.
If you need several rules, put them in a single policy definition outside dbt
(for example in Snowflake SQL or IaC such as Terraform); see [docs/boundaries.md](docs/boundaries.md).

Adapter-independent reference authorization belongs with [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) (`meta.authorize`).

## Motivation

dbt-snowflake's built-in `row_access_policy` config is valuable, but it is not enough for continuous governance in a growing project:

1. **Existing tables are not re-applied.** The built-in path attaches a policy at `CREATE` / replace time. Relations that already exist (or lose their attachment later) do not converge back to the declared policy without manual `ALTER`.
2. **Downstream inheritance is not enforceable.** Declaring a RAP on an upstream model does not require referencing models to declare one as well, so protected data can leak into unprotected terminals.
3. **Policies cannot be removed or replaced from config alone.** Clearing or changing `row_access_policy` in dbt does not drop a stale attachment on Snowflake without an authoritative reconcile step.

This package closes those gaps so RAP intent in dbt stays true in Snowflake: bulk apply (including ADD / DROP / replace on existing relations, and DROP when config clears the policy) and a graph check that fails when downstream models omit a required policy. The goal is stricter, repeatable row-level governance as part of normal `dbt run` / `build` workflows—not one-off DDL.

## Requirements

- dbt Core 1.10 or later (`require-dbt-version: [">=1.10.0", "<2.0.0"]`)
- dbt Fusion 2.0 preview is compatible and covered by CI

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
    # Replace on mismatch; drop when row_access_policy is cleared (default true)
    apply_authoritatively: true
```

Downstream check walk:

- Materialization in `passthrough_materializations` → continue through the node (unless it declares its own policy, which becomes a trust boundary).
- Any other model/snapshot → terminal; must satisfy the upstream `enforce_policy`.
- An `allow_without_row_access_policy` match exempts that terminal from failing the check (`["*"]` exempts every terminal collected from that RAP model).

### Vars reference

| Option | Hook | Meaning |
|--------|------|---------|
| `passthrough_materializations` | check | Materializations the graph walk passes through without requiring a policy declaration |
| `exclude_resource_types` | check | Resource types ignored by the check |
| `apply_authoritatively` | apply | `true` (default): replace attached policy when it differs from config, and drop attachments when `row_access_policy` is cleared. `false`: only `ADD` when nothing is attached; leave mismatches (including attached-but-cleared) |

Wiring the hooks is the on/off switch:

- Check is wired ⇒ violations **fail** any command that executes the hook (full graph).
- Apply is wired ⇒ on `run` / `build` / `snapshot` / `retry`, apply to **selected** models/snapshots that declare `row_access_policy`. When `apply_authoritatively=true`, also include selected relation nodes with no RAP so cleared config can DROP. On `run-operation`, apply to all eligible nodes in the project graph (dbt does not populate selection for that command).

Identifier assumption: **unquoted** Snowflake identifiers only (case-insensitive). Case-sensitive / `quote_identifiers` relations are not supported for apply/fetch.

Protect a model:

```sql
{{
  config(
    materialized='table',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
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
| `enforce_policy` | `inherit` \| `any` \| `explicit` |
| `required_policy` | Single policy FQN when `enforce_policy` is `explicit` |
| `allow_without_row_access_policy` | Exempt downstream names (or regexes), or `'*'`. Matched against `name`, `package.name`, and `unique_id`. Bare names match across packages. Use `['*']` when this RAP model should not fail any downstream terminal. |

### `enforce_policy`

| Value | Meaning |
|-------|---------|
| `inherit` (default) | Downstream primary FQN must equal this node's primary FQN |
| `any` | Downstream must declare any row access policy |
| `explicit` | Downstream primary FQN must equal `required_policy` |

### Apply behavior

`apply_row_access_policies()` (Snowflake only):

1. Targets = (`run`/`build`/`snapshot`/`retry`: current selection; `run-operation`: project graph) ∩ models/snapshots with `row_access_policy`, plus (when `apply_authoritatively=true`) selected relation nodes with no RAP declaration
2. Fetch existing relations (`information_schema.tables`, including `is_dynamic`)
3. Fetch attachments only for relations that exist (relation-scoped `policy_references` with fully qualified `ref_entity_name`) — missing objects are skipped with a warning because `POLICY_REFERENCES` errors on absent names. Attached columns come from `REF_COLUMN_NAME` when present, otherwise `REF_ARG_COLUMN_NAMES` (common for VIEW RAPs). Policy FQNs in generated `ALTER` DDL are normalized to uppercase for unquoted identifiers.
4. Plan and run `ALTER ... ADD` / named `DROP ..., ADD` / (`DROP ALL` then `ADD`) / named `DROP` / `DROP ALL` when `apply_authoritatively=true`. Cleared config (`desired=none`) with an attachment becomes DROP. When the desired policy and columns already match the attachment, the planner is a no-op.
5. Commands: `run`, `build`, `snapshot`, `retry`, `run-operation`

### Privileges

The dbt role needs ownership of target objects (or schema-level `APPLY ROW ACCESS POLICY`) and `APPLY` on the policies. Policies must already exist. `POLICY_REFERENCES` visibility is stricter than ALTER: lacking the right privileges can error or return no rows (planner may then attempt ADD).

## Development

```bash
mise install --locked
uv sync
mise run lint
mise run test
mise run test:fusion
```

Check dbt Fusion compatibility directly (same flow as CI):

```bash
curl -fsSL https://public.cdn.getdbt.com/fs/install/install.sh | sh -s -- --to /tmp/dbt-fusion-bin --update
/tmp/dbt-fusion-bin/dbt deps --project-dir unit_tests --profiles-dir unit_tests
/tmp/dbt-fusion-bin/dbt run-operation run_unit_tests --project-dir unit_tests --profiles-dir unit_tests
/tmp/dbt-fusion-bin/dbt deps --project-dir integration_tests --profiles-dir integration_tests
/tmp/dbt-fusion-bin/dbt parse --project-dir integration_tests --profiles-dir integration_tests
uv run python integration_tests/run_downstream_failure_tests.py --dbt-executable /tmp/dbt-fusion-bin/dbt
/tmp/dbt-fusion-bin/dbt compile --project-dir integration_tests --profiles-dir integration_tests
```

Local Snowflake apply E2E (not CI): set `DBT_SNOWFLAKE_RAP_E2E_*` and run
`mise run test:snowflake-e2e` (dbt Core) or `mise run test:snowflake-e2e:fusion`
(dbt Fusion). See [snowflake_e2e/README.md](snowflake_e2e/README.md).

## Documentation

- [Package boundaries](docs/boundaries.md)
- [Contributing](CONTRIBUTING.md)
- [Securefix / CI automation](docs/securefix.md)
- [Releasing](docs/releasing.md)
- [Security](SECURITY.md)

## License

Apache License 2.0. See [LICENSE](LICENSE).
