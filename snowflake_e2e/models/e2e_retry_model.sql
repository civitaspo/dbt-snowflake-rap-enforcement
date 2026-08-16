{{
  config(
    materialized='table',
    row_access_policy=var('e2e_policy_fqn') ~ ' on (tenant_id)'
  )
}}

{# Fail at execution when DBT_SNOWFLAKE_RAP_E2E_RETRY_FAIL=1 so on-run-end
   still runs. A compiler error would abort before hooks. #}
{% if env_var('DBT_SNOWFLAKE_RAP_E2E_RETRY_FAIL', '0') == '1' %}
select 1::number as tenant_id from nonexistent_e2e_retry_failure_table
{% else %}
select 1::number as tenant_id, 'retry' as payload
{% endif %}
