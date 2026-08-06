{% macro test_alter_row_access_policy_sql() %}
  {% set add_sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
    'ANALYTICS',
    'DWH',
    'ORDERS',
    'BASE TABLE',
    'system.row_access_policies.p1',
    'tenant_id'
  ) %}
  {{ dbt_unittest.assert_equals(
    add_sql,
    'alter TABLE "ANALYTICS"."DWH"."ORDERS" add row access policy system.row_access_policies.p1 on (tenant_id)'
  ) }}

  {% set view_sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
    'ANALYTICS',
    'DWH',
    'ORDERS_V',
    'VIEW',
    'system.row_access_policies.p1',
    'tenant_id'
  ) %}
  {{ dbt_unittest.assert_true('alter VIEW' in view_sql) }}

  {% set replace_sql = dbt_snowflake_rap_enforcement.alter_drop_add_row_access_policy_sql(
    'ANALYTICS',
    'DWH',
    'ORDERS',
    'BASE TABLE',
    'system.row_access_policies.old',
    'system.row_access_policies.new',
    'tenant_id'
  ) %}
  {{ dbt_unittest.assert_true('drop row access policy system.row_access_policies.old' in replace_sql) }}
  {{ dbt_unittest.assert_true('add row access policy system.row_access_policies.new' in replace_sql) }}
{% endmacro %}

{% macro test_build_policy_references_sql() %}
  {% set sql = dbt_snowflake_rap_enforcement.build_policy_references_sql(
    'ANALYTICS',
    ['system.row_access_policies.p1', 'system.row_access_policies.p2']
  ) %}
  {{ dbt_unittest.assert_true('union all' in sql) }}
  {{ dbt_unittest.assert_true("policy_name => 'system.row_access_policies.p1'" in sql) }}
  {{ dbt_unittest.assert_true("policy_name => 'system.row_access_policies.p2'" in sql) }}
  {{ dbt_unittest.assert_true('"ANALYTICS".information_schema.policy_references' in sql) }}
{% endmacro %}

{% macro test_build_existing_relations_sql() %}
  {% set sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
    'ANALYTICS',
    ['dwh', 'mart']
  ) %}
  {{ dbt_unittest.assert_true('"ANALYTICS".information_schema.tables' in sql) }}
  {{ dbt_unittest.assert_true("'DWH'" in sql) }}
  {{ dbt_unittest.assert_true("'MART'" in sql) }}
{% endmacro %}
