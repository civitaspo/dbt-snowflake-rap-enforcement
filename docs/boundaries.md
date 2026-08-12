# Package boundaries

## One-sentence split

`dbt-snowflake-rap-enforcement` attaches a Snowflake row access policy (including to existing relations) and checks downstream row access policy requirements declared on protected models. Who may `ref()` a resource stays in [`dbt-authorized-models`](https://github.com/civitaspo/dbt-authorized-models) via `meta.authorize`.

## Platform constraint

Snowflake allows **one row access policy per table/view/dynamic table**. This package never attaches multiple policies.
If you need several rules, put them in a single policy definition outside dbt
(for example in Snowflake SQL or IaC such as Terraform).

## Responsibility matrix

| Concern | Package |
|---------|---------|
| Allow-list of referencing nodes (`meta.authorize`) | `dbt-authorized-models` |
| Apply row access policy to relations (`ALTER ... ADD/DROP ROW ACCESS POLICY`) | `dbt-snowflake-rap-enforcement` |
| Downstream must also declare a row access policy (`meta.row_access_policy_enforcement`) | `dbt-snowflake-rap-enforcement` |
| Row access policy SQL body / grants | Outside dbt (Snowflake SQL / IaC / ops) — not either package |

Do **not** put Snowflake RAP DDL into `dbt-authorized-models`.

## Consumer wiring (root project)

```yaml
# packages.yml
packages:
  - git: "https://github.com/civitaspo/dbt-authorized-models.git"
    revision: v0.2.0  # bump to the latest release tag
  - git: "https://github.com/civitaspo/dbt-snowflake-rap-enforcement.git"
    revision: v0.1.0  # bump to the latest release tag

# dbt_project.yml
on-run-start:
  - "{{ dbt_authorized_models.check_authorization() }}"
  - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policies() }}"

on-run-end:
  - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"

vars:
  dbt_snowflake_rap_enforcement:
    passthrough_materializations: [view, ephemeral]
    apply_authoritatively: true
```

Package `dbt_project.yml` files do not inject hooks; the root project must opt in.

## Metadata contract

- Built-in Snowflake config: `row_access_policy: "db.schema.policy on (col)"` (sole apply target).
- Package meta: `meta.row_access_policy_enforcement`
  - `enforce_policy`: `inherit` | `any` | `explicit`
  - `required_policy`: single FQN string (for `explicit`)
  - `allow_without_row_access_policy`: list of exempt model/snapshot names (or `'*'`; use `['*']` to skip failing any downstream terminal from this RAP model)

Package vars live under `vars.dbt_snowflake_rap_enforcement` (same as the package name). See the README for the full schema.
