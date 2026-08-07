{{
  config(
    materialized='table',
    enabled=var('enable_global_meta_cases', false),
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)'
  )
}}

{# Case 2: inherits allow_without_row_access_policy: ["*"] from dbt_project.yml. #}
select 1 as tenant_id, 'open' as payload
