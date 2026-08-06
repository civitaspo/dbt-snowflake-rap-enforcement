# Package boundaries

## One-sentence split

`dbt-snowflake-rap-enforcement` attaches Snowflake row access policies (including to existing relations) and enforces RAP-side downstream requirements declared on protected models. Who may `ref()` a resource stays in [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) via `meta.authorize`.

## Responsibility matrix

| Concern | Package |
|---------|---------|
| Allow-list of referencing nodes (`meta.authorize`) | `dbt-authorized-models` |
| Apply RAP to relations (`ALTER ... ADD ROW ACCESS POLICY`) | `dbt-snowflake-rap-enforcement` |
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

- Built-in Snowflake config: `row_access_policy: "db.schema.policy on (col)"` (single string; CREATE-time path).
- Package meta (Fusion-safe): `meta.row_access_policy_enforcement`
  - `additional_row_access_policies`: extra `"fqn on (cols)"` strings (requires primary `row_access_policy`)
  - `require_downstream`, `enforce_policy`, `policies`, `allow_without_rap`

See the package README for the full schema.
