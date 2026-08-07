{{
  config(
    materialized='table',
    enabled=var('enable_global_meta_violation', false)
  )
}}

{# Case 3: unprotected terminal after strict_protected must fail validation. #}
select * from {{ ref('strict_protected') }}
