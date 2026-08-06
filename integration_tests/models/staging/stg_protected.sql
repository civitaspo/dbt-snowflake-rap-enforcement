{{
  config(
    materialized='view',
    row_access_policy='system.row_access_policies.tenant_policy on (tenant_id)',
    meta={
      'row_access_policy_enforcement': {
        'require_downstream': true,
        'enforce_policy': 'inherit',
        'allow_without_rap': [
          {'resource_type': 'model', 'name': 'allowed_plain_table'}
        ]
      }
    }
  )
}}

select 1 as tenant_id, 'ok' as payload
