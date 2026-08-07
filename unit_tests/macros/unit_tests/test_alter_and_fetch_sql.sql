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

  {% set dynamic_sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
    'ANALYTICS',
    'DWH',
    'ORDERS_DT',
    'BASE TABLE',
    'system.row_access_policies.p1',
    'tenant_id',
    'YES'
  ) %}
  {{ dbt_unittest.assert_true('alter DYNAMIC TABLE' in dynamic_sql) }}

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
    'analytics',
    [
      {'schema': 'dwh', 'identifier': 'orders', 'domain': 'TABLE'},
      {'schema': 'dwh', 'identifier': 'orders_v', 'domain': 'VIEW'}
    ]
  ) %}
  {{ dbt_unittest.assert_true('union all' in sql) }}
  {{ dbt_unittest.assert_true("ref_entity_name => 'ANALYTICS.DWH.ORDERS'" in sql) }}
  {{ dbt_unittest.assert_true("ref_entity_domain => 'TABLE'" in sql) }}
  {{ dbt_unittest.assert_true("ref_entity_name => 'ANALYTICS.DWH.ORDERS_V'" in sql) }}
  {{ dbt_unittest.assert_true("ref_entity_domain => 'VIEW'" in sql) }}
  {{ dbt_unittest.assert_true('upper(ref_database_name) as ref_database' in sql) }}
  {{ dbt_unittest.assert_true('upper(ref_schema_name) as ref_schema' in sql) }}
  {{ dbt_unittest.assert_true('ANALYTICS.information_schema.policy_references' in sql) }}
{% endmacro %}

{% macro test_resolve_apply_target_node_ids() %}
  {% set selected = ['model.proj.a'] %}
  {% set graph_ids = ['model.proj.a', 'model.proj.b'] %}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids(selected, 'run', graph_ids),
    selected
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids([], 'run', graph_ids) | length,
    0
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids(none, 'build', graph_ids) | length,
    0
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids([], 'run-operation', graph_ids),
    graph_ids
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids(none, 'run-operation', graph_ids),
    graph_ids
  ) }}
{% endmacro %}

{% macro test_build_existing_relations_sql() %}
  {% set sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
    'analytics',
    ['dwh', 'mart']
  ) %}
  {{ dbt_unittest.assert_true('ANALYTICS.information_schema.tables' in sql) }}
  {{ dbt_unittest.assert_true('is_dynamic' in sql) }}
  {{ dbt_unittest.assert_true("'DWH'" in sql) }}
  {{ dbt_unittest.assert_true("'MART'" in sql) }}
{% endmacro %}
