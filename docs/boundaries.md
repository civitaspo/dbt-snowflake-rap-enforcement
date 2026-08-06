# Package boundaries

## One-sentence split

`dbt-snowflake-rap-enforcement` attaches a Snowflake row access policy (including to existing relations) and enforces RAP-side downstream requirements declared on protected models. Who may `ref()` a resource stays in [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) via `meta.authorize`.

## Platform constraint

Snowflake allows **one RAP per table/view/dynamic table**. This package never attaches multiple policies. Encode multiple rules in a single policy body outside dbt.

## Responsibility matrix

| Concern | Package |
|---------|---------|
| Allow-list of referencing nodes (`meta.authorize`) | `dbt-authorized-models` |
| Apply RAP to relations (`ALTER ... ADD/DROP ROW ACCESS POLICY`) | `dbt-snowflake-rap-enforcement` |
| Downstream must also declare RAP (`meta.row_access_policy_enforcement`) | `dbt-snowflake-rap-enforcement` |
| Row access policy SQL body / grants | Warehouse / Terraform / ops — not either package |

Do **not** put Snowflake RAP DDL into `dbt-authorized-models`. Prefer a shared *contract* (protected-side ownership of policy) over merging implementations.

## Consumer wiring (root project)

```yaml
# packages.yml
packages:
  - git: "https://github.com/civitaspo/dbt-authorized-models.git"
    revision: v0.2.0
  - git: "https://github.com/civitaspo/dbt-snowflake-rap-enforcement.git"
    revision: v0.1.0

# dbt_project.yml
on-run-start:
  - "{{ dbt_authorized_models.check_authorization() }}"
  - "{{ dbt_snowflake_rap_enforcement.check_downstream_rap() }}"

on-run-end:
  - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"

vars:
  dbt_authorized_models:
    enforce: true
  dbt_snowflake_rap_enforcement:
    enforce_downstream: false  # warn first, then true
```

Package `dbt_project.yml` files do not inject hooks; the root project must opt in.

## Metadata contract

- Built-in Snowflake config: `row_access_policy: "db.schema.policy on (col)"` (single string; CREATE-time path and sole apply target).
- Package meta (Fusion-safe): `meta.row_access_policy_enforcement`
  - `require_downstream` (default `true` when a RAP is declared)
  - `enforce_policy`: `inherit` | `any` | `explicit`
  - `required_policy`: single FQN string (required when `enforce_policy` is `explicit`)
  - `allow_without_rap`

Removed / rejected keys: `additional_row_access_policies`, `policies`, `explicit-one-of`, `explicit-all`.

See the package README for the full schema.
