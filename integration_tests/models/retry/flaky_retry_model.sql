{{
  config(
    materialized='table',
    enabled=var('enable_retry_models', false)
  )
}}

{# Fail at execution when the retry harness sets DBT_SNOWFLAKE_RAP_RETRY_FAIL=1.
   A compiler error would abort before on-run-start, so this stays valid SQL. #}
{% if env_var('DBT_SNOWFLAKE_RAP_RETRY_FAIL', '0') == '1' %}
select 1 as id from nonexistent_retry_failure_table
{% else %}
select 1 as id
{% endif %}

