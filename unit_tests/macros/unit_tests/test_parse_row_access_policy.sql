{% macro test_parse_row_access_policy() %}
  {% set parsed = dbt_snowflake_rap_enforcement.parse_row_access_policy(
    'system.row_access_policies.example_tenant_access_policy on (tenant_id)'
  ) %}
  {{ dbt_unittest.assert_equals(
    parsed.policy_fqn,
    'system.row_access_policies.example_tenant_access_policy'
  ) }}
  {{ dbt_unittest.assert_equals(parsed.columns_sql, 'tenant_id') }}
  {{ dbt_unittest.assert_equals(parsed.columns_key, 'tenant_id') }}
  {{ dbt_unittest.assert_equals(
    parsed.policy_fqn_key,
    'system.row_access_policies.example_tenant_access_policy'
  ) }}

  {% set parsed_multi = dbt_snowflake_rap_enforcement.parse_row_access_policy(
    'db.sch.policy ON ( col_b , col_a )'
  ) %}
  {{ dbt_unittest.assert_equals(parsed_multi.policy_fqn, 'db.sch.policy') }}
  {{ dbt_unittest.assert_equals(parsed_multi.columns_key, 'col_a,col_b') }}

  {# Policy names ending in _on need a separate ON keyword; use greedy FQN match. #}
  {% set parsed_on_suffix = dbt_snowflake_rap_enforcement.parse_row_access_policy(
    'db.sch.policy_on on (tenant_id)'
  ) %}
  {{ dbt_unittest.assert_equals(parsed_on_suffix.policy_fqn, 'db.sch.policy_on') }}
  {{ dbt_unittest.assert_equals(parsed_on_suffix.columns_key, 'tenant_id') }}

  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.normalize_columns_key('"MyCol", other'),
    'mycol,other'
  ) }}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.parse_row_access_policy(none) is none
  ) }}
{% endmacro %}
