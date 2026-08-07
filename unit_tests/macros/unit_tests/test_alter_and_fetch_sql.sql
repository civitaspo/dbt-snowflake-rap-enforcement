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
    'alter TABLE "ANALYTICS"."DWH"."ORDERS" add row access policy "system"."row_access_policies"."p1" on (tenant_id)'
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
  {{ dbt_unittest.assert_true(
    'drop row access policy "system"."row_access_policies"."old"' in replace_sql
  ) }}
  {{ dbt_unittest.assert_true(
    'add row access policy "system"."row_access_policies"."new"' in replace_sql
  ) }}

  {% set drop_all_sql = dbt_snowflake_rap_enforcement.alter_drop_all_row_access_policies_sql(
    'ANALYTICS',
    'DWH',
    'ORDERS',
    'BASE TABLE'
  ) %}
  {{ dbt_unittest.assert_equals(
    drop_all_sql,
    'alter TABLE "ANALYTICS"."DWH"."ORDERS" drop all row access policies'
  ) }}
  {{ dbt_unittest.assert_true(',' not in drop_all_sql) }}
{% endmacro %}

{% macro test_ref_entity_domain_for_materialized() %}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.ref_entity_domain_for_materialized('view'),
    'VIEW'
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.ref_entity_domain_for_materialized('materialized_view'),
    'VIEW'
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.ref_entity_domain_for_materialized('table'),
    'TABLE'
  ) }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.ref_entity_domain_for_materialized('incremental'),
    'TABLE'
  ) }}
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
  {{ dbt_unittest.assert_true('"ANALYTICS".information_schema.policy_references' in sql) }}
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
  {# Even if dbt puts the operation id in selected_resources, use the graph. #}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids(
      ['operation.proj.run_unit_tests'],
      'run-operation',
      graph_ids
    ),
    graph_ids
  ) }}
{% endmacro %}

{% macro test_build_existing_relations_sql() %}
  {% set sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
    'analytics',
    ['dwh', 'mart']
  ) %}
  {{ dbt_unittest.assert_true('"ANALYTICS".information_schema.tables' in sql) }}
  {{ dbt_unittest.assert_true('is_dynamic' in sql) }}
  {{ dbt_unittest.assert_true("'DWH'" in sql) }}
  {{ dbt_unittest.assert_true("'MART'" in sql) }}
{% endmacro %}

{% macro test_index_helpers_and_missing_plan() %}
  {% set relations = dbt_snowflake_rap_enforcement.index_existing_relations([
    {
      'table_catalog': 'analytics',
      'table_schema': 'dwh',
      'table_name': 'orders',
      'table_type': 'BASE TABLE',
      'is_dynamic': 'NO'
    }
  ]) %}
  {{ dbt_unittest.assert_true('ANALYTICS.DWH.ORDERS' in relations) }}

  {% set attachments = dbt_snowflake_rap_enforcement.index_policy_attachments([
    {
      'ref_database': 'ANALYTICS',
      'ref_schema': 'DWH',
      'ref_entity_name': 'ORDERS',
      'policy_fqn_key': 'db.sch.p1',
      'columns_key': 'c1',
      'policy_fqn': 'db.sch.p1'
    }
  ]) %}
  {{ dbt_unittest.assert_true('ANALYTICS.DWH.ORDERS' in attachments) }}
  {{ dbt_unittest.assert_equals(
    attachments['ANALYTICS.DWH.ORDERS']['db.sch.p1'].columns_key,
    'c1'
  ) }}

  {% set desired = dbt_snowflake_rap_enforcement.parse_row_access_policy('db.sch.p1 on (c1)') %}
  {% set targets = [{
    'unique_id': 'model.test.orders',
    'name': 'orders',
    'database': 'analytics',
    'schema': 'dwh',
    'identifier': 'orders',
    'desired': desired
  }] %}
  {% set missing_plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
    targets,
    {},
    {},
    true
  ) %}
  {{ dbt_unittest.assert_equals(missing_plan.actions | length, 0) }}
  {{ dbt_unittest.assert_equals(missing_plan.skipped_missing | length, 1) }}
  {{ dbt_unittest.assert_equals(
    missing_plan.skipped_missing[0].rel_key,
    'ANALYTICS.DWH.ORDERS'
  ) }}
{% endmacro %}
