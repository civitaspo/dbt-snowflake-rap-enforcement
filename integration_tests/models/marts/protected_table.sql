{{
  config(
    materialized='table',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)'
  )
}}

select * from {{ ref('stg_protected') }}
