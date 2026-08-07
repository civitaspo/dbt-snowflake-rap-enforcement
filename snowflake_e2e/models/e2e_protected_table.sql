{{
  config(
    materialized='table',
    row_access_policy=var('e2e_policy_fqn') ~ ' on (tenant_id)'
  )
}}

select 1::number as tenant_id, 'e2e' as payload
