{{
  config(
    materialized='view',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
        'enforce_policy': 'inherit',
        'allow_without_row_access_policy': [
          'allowed_plain_table'
        ]
      }
    }
  )
}}

select 1 as tenant_id, 'ok' as payload
