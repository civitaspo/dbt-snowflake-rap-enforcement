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
    revision: v0.1.0  # bump to the latest release tag
```

```bash
dbt deps
```

## Quick start

```yaml
# dbt_project.yml (root project)
on-run-start:
  - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policies() }}"

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
| `policy_references_chunk_size` | apply | Max relations per `POLICY_REFERENCES(ref_entity_name => ...)` batch (default `75`). Used only for the exact fallback path after policy-name lookup |

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
2. Fetch existing relations (`information_schema.tables`, including `is_dynamic`), filtered to selected schemas and identifiers
3. Fetch attachments with a hybrid inventory: one `POLICY_REFERENCES(policy_name => ...)` lookup per distinct desired policy, then relation-scoped `POLICY_REFERENCES(ref_entity_name => ...)` only for RAP-declared targets missing from that index, in batches of `policy_references_chunk_size`. Matching bulk attachments are proven no-ops. Missing objects are skipped with a warning because `POLICY_REFERENCES` errors on absent names. Attached columns come from `REF_COLUMN_NAME` when present, otherwise `REF_ARG_COLUMN_NAMES` (common for VIEW RAPs). Policy FQNs in generated `ALTER` DDL are normalized to uppercase for unquoted identifiers. Do not use `ACCOUNT_USAGE.POLICY_REFERENCES` (latency can reach two hours).
4. Plan and run `ALTER ... ADD` / named `DROP ..., ADD` / (`DROP ALL` then `ADD`) / named `DROP` / `DROP ALL` when `apply_authoritatively=true`. Cleared config (`desired=none`) with an attachment becomes DROP. When the desired policy and columns already match the attachment, the planner is a no-op.
5. Commands: `run`, `build`, `snapshot`, `retry`, `run-operation`

### Privileges

The dbt role needs ownership of target objects (or schema-level `APPLY ROW ACCESS POLICY`) and `APPLY` on the policies. Policies must already exist. `POLICY_REFERENCES` visibility is stricter than ALTER: lacking the right privileges can error or return no rows (planner may then attempt ADD).

## Performance and troubleshooting

The downstream check still validates the **full graph** on every command that executes the hook, including each non-empty `dbt retry`. Selection and retry queues do not shrink that contract.

Traversal is indexed: the hook builds a reverse adjacency list once, then walks only real child edges from each RAP source. It does **not** rescan every manifest node per RAP source or per passthrough hop.

On a project with about 15,000 graph nodes and 6,000 RAP sources, the previous walk examined at least `6,000 × 15,000` nodes per invocation (90 million), and a build plus three non-empty retries repeated that four times. The indexed walk examines each reachable child edge instead.

Each hook execution logs a parseable metrics line:

```text
(dbt-snowflake-rap-enforcement) Downstream row access policy check metrics: graph_nodes=...; rap_sources=...; dependency_edges=...; ancestor_visits=...; child_edges_examined=...; checked=...
```

| Field | Meaning |
|-------|---------|
| `graph_nodes` | Nodes in `graph.nodes` for this invocation |
| `rap_sources` | Nodes that declare `row_access_policy` |
| `dependency_edges` | `depends_on.nodes` edges in that graph |
| `ancestor_visits` | Walker entries (RAP sources plus traversed passthroughs) |
| `child_edges_examined` | Child edges looked at during those walks |
| `checked` | Unique downstream terminal/source pairs evaluated |

`checked` is the number of unique relationships, not the number of node scans. After this optimization, `child_edges_examined` should stay on the order of reachable edges, not `rap_sources × graph_nodes`.

Use those signals to split a slow `dbt build` / `dbt retry` into phases:

1. **Start-hook / Jinja time.** Look for the metrics line and the hook operation timing in `run_results.json`. Repeated high start-hook time with the same full-graph counts on every retry points at the downstream walk.
2. **Apply inventory and DDL.** `apply_row_access_policies` logs `targets`, `bulk_policies`, `fallback_relations`, `fallback_batches`, `attachment_rows`, `planned_actions`, and `applied`. Pair that with Snowflake query history. Upgrade to **0.5.1 or later** before diagnosing apply inventory: earlier versions compiled one giant relation-scoped `POLICY_REFERENCES` `UNION ALL`.
3. **First-time convergence vs steady state.** Thousands of `planned_actions` can make the first apply expensive because each ALTER is a sequential `run_query`. A later run that logs few or no actions, but still spends a long time before the first model, is the graph walk rather than Snowflake DDL.

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
uv run python integration_tests/run_retry_tests.py --dbt-executable /tmp/dbt-fusion-bin/dbt
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
