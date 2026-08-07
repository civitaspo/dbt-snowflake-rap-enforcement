{{
  config(
    materialized='table',
    enabled=var('enable_global_meta_cases', false)
  )
}}

{# Case 1: project-level enforcement meta must not affect models without RAP. #}
select 1 as tenant_id, 'plain' as payload
