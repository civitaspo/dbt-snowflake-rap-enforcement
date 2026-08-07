{% macro test_plan_relation_row_access_policy() %}
  {% set desired = dbt_snowflake_rap_enforcement.parse_row_access_policy(
    'db.sch.p1 on (col_b, col_a)'
  ) %}

  {% set attached_match = {
    'db.sch.p1': {
      'policy_fqn': 'DB.SCH.P1',
      'policy_fqn_key': 'db.sch.p1',
      'columns_key': 'col_a,col_b'
    }
  } %}
  {% set noop = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(desired, attached_match, true) %}
  {{ dbt_unittest.assert_equals(noop.action, 'noop') }}

  {% set add_plan = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(desired, {}, true) %}
  {{ dbt_unittest.assert_equals(add_plan.action, 'add') }}

  {% set attached_other = {
    'db.sch.old': {
      'policy_fqn': 'db.sch.old',
      'policy_fqn_key': 'db.sch.old',
      'columns_key': 'col_a,col_b'
    }
  } %}
  {% set replace_plan = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(
    desired,
    attached_other,
    true
  ) %}
  {{ dbt_unittest.assert_equals(replace_plan.action, 'replace') }}
  {{ dbt_unittest.assert_equals(replace_plan.existing_policy_fqn, 'db.sch.old') }}

  {% set leave_plan = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(
    desired,
    attached_other,
    false
  ) %}
  {{ dbt_unittest.assert_equals(leave_plan.action, 'leave_mismatch') }}
  {{ dbt_unittest.assert_equals(
    dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(desired, attached_other, true).action,
    'replace'
  ) }}

  {% set attached_multi = {
    'db.sch.old': {
      'policy_fqn': 'db.sch.old',
      'policy_fqn_key': 'db.sch.old',
      'columns_key': 'x'
    },
    'db.sch.extra': {
      'policy_fqn': 'db.sch.extra',
      'policy_fqn_key': 'db.sch.extra',
      'columns_key': 'y'
    }
  } %}
  {% set replace_all = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(
    desired,
    attached_multi,
    true
  ) %}
  {{ dbt_unittest.assert_equals(replace_all.action, 'replace_all') }}
  {{ dbt_unittest.assert_true('db.sch.old' in replace_all.existing_policy_fqn) }}
  {{ dbt_unittest.assert_true('db.sch.extra' in replace_all.existing_policy_fqn) }}

  {% set leave_multi = dbt_snowflake_rap_enforcement.plan_relation_row_access_policy(
    desired,
    attached_multi,
    false
  ) %}
  {{ dbt_unittest.assert_equals(leave_multi.action, 'leave_mismatch') }}
  {{ dbt_unittest.assert_true(leave_multi.existing_policy_fqn is not none) }}
{% endmacro %}

{% macro test_plan_row_access_policy_alters() %}
  {% set desired = dbt_snowflake_rap_enforcement.parse_row_access_policy('db.sch.p1 on (c1)') %}
  {% set targets = [{
    'unique_id': 'model.test.orders',
    'name': 'orders',
    'database': 'analytics',
    'schema': 'dwh',
    'identifier': 'orders',
    'desired': desired
  }] %}
  {% set relations = {
    'ANALYTICS.DWH.ORDERS': {
      'database': 'ANALYTICS',
      'schema': 'DWH',
      'identifier': 'ORDERS',
      'table_type': 'BASE TABLE',
      'is_dynamic': 'NO'
    }
  } %}
  {% set plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(targets, relations, {}, true) %}
  {{ dbt_unittest.assert_equals(plan.actions | length, 1) }}
  {{ dbt_unittest.assert_equals(plan.actions[0].action, 'add') }}
  {{ dbt_unittest.assert_equals(plan.skipped_missing | length, 0) }}

  {% set plan_missing = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(targets, {}, {}, true) %}
  {{ dbt_unittest.assert_equals(plan_missing.actions | length, 0) }}
  {{ dbt_unittest.assert_equals(plan_missing.skipped_missing | length, 1) }}
  {{ dbt_unittest.assert_equals(plan_missing.skipped_missing[0].rel_key, 'ANALYTICS.DWH.ORDERS') }}
{% endmacro %}

{% macro test_plan_authoritative_replace_alter() %}
  {# Wrong attached policy + apply_authoritatively=true => REPLACE (drop+add). #}
  {% set desired = dbt_snowflake_rap_enforcement.parse_row_access_policy(
    'system.row_access_policies.desired on (tenant_id)'
  ) %}
  {% set targets = [{
    'unique_id': 'model.test.orders',
    'name': 'orders',
    'database': 'analytics',
    'schema': 'dwh',
    'identifier': 'orders',
    'desired': desired
  }] %}
  {% set relations = {
    'ANALYTICS.DWH.ORDERS': {
      'database': 'ANALYTICS',
      'schema': 'DWH',
      'identifier': 'ORDERS',
      'table_type': 'BASE TABLE',
      'is_dynamic': 'NO'
    }
  } %}
  {% set attachments = {
    'ANALYTICS.DWH.ORDERS': {
      'system.row_access_policies.stale': {
        'policy_fqn': 'system.row_access_policies.stale',
        'policy_fqn_key': 'system.row_access_policies.stale',
        'columns_key': 'tenant_id'
      }
    }
  } %}

  {% set authoritative = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
    targets,
    relations,
    attachments,
    true
  ) %}
  {{ dbt_unittest.assert_equals(authoritative.actions | length, 1) }}
  {{ dbt_unittest.assert_equals(authoritative.left_mismatches | length, 0) }}
  {{ dbt_unittest.assert_equals(authoritative.actions[0].action, 'replace') }}
  {{ dbt_unittest.assert_equals(
    authoritative.actions[0].existing_policy_fqn,
    'system.row_access_policies.stale'
  ) }}

  {% set action = authoritative.actions[0] %}
  {% set replace_sql = dbt_snowflake_rap_enforcement.alter_drop_add_row_access_policy_sql(
    action.relation.database,
    action.relation.schema,
    action.relation.identifier,
    action.relation.table_type,
    action.existing_policy_fqn,
    action.desired.policy_fqn,
    action.desired.columns_sql,
    action.relation.is_dynamic
  ) %}
  {{ dbt_unittest.assert_true(
    'drop row access policy "system"."row_access_policies"."stale"' in replace_sql
  ) }}
  {{ dbt_unittest.assert_true(
    'add row access policy "system"."row_access_policies"."desired"' in replace_sql
  ) }}
  {{ dbt_unittest.assert_true('on (tenant_id)' in replace_sql) }}

  {% set non_authoritative = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
    targets,
    relations,
    attachments,
    false
  ) %}
  {{ dbt_unittest.assert_equals(non_authoritative.actions | length, 0) }}
  {{ dbt_unittest.assert_equals(non_authoritative.left_mismatches | length, 1) }}
  {{ dbt_unittest.assert_equals(
    non_authoritative.left_mismatches[0].existing_policy_fqn,
    'system.row_access_policies.stale'
  ) }}
{% endmacro %}
