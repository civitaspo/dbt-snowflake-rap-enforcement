{{
  config(
    materialized='table',
    enabled=var('enable_retry_models', false)
  )
}}

{# Fail when the retry harness sets DBT_SNOWFLAKE_RAP_RETRY_FAIL=1. #}
{% if env_var('DBT_SNOWFLAKE_RAP_RETRY_FAIL', '0') == '1' %}
  {{ exceptions.raise_compiler_error('intentional retry failure') }}
{% endif %}

select 1 as id
