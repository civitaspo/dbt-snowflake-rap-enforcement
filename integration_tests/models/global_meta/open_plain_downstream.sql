{{
  config(
    materialized='table',
    enabled=var('enable_global_meta_cases', false)
  )
}}

select * from {{ ref('open_protected') }}
