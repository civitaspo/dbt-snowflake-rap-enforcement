{#
  No row_access_policy: used to verify authoritative apply DROPs a stale
  attachment when config clears the policy.
#}
{{ config(materialized='table') }}

select 1::number as tenant_id, 'cleared' as payload
