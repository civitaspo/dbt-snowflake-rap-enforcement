{# Empty allow_without list clears project-level allow_without ["*"] (dbt merges meta). #}
{{
  config(
    materialized='table',
    enabled=var('enable_global_meta_cases', false),
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
        'enforce_policy': 'inherit',
        'allow_without_row_access_policy': []
      }
    }
  )
}}

select * from {{ ref('open_protected') }}
