{{
  config(
    materialized='table',
    enabled=var('enable_violation_models', false)
  )
}}

select * from {{ ref('stg_protected') }}
