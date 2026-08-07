{#
  dbt-snowflake attaches RAP during CREATE (... WITH ROW ACCESS POLICY).
  post_hook strips it so on-run-end apply_row_access_policies() must ADD
  onto a bare table.
#}
{{
  config(
    materialized='table',
    row_access_policy=var('e2e_policy_fqn') ~ ' on (tenant_id)',
    post_hook=[
      "alter table {{ this }} drop all row access policies"
    ]
  )
}}

select 1::number as tenant_id, 'e2e' as payload
