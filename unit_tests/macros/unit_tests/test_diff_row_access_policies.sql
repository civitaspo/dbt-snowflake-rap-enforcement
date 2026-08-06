{% macro test_diff_row_access_policies() %}
  {% set desired = [
    dbt_snowflake_rap_enforcement.parse_row_access_policy('db.sch.p1 on (c1)'),
    dbt_snowflake_rap_enforcement.parse_row_access_policy('db.sch.p2 on (c2)')
  ] %}

  {% set attached = {
    'db.sch.p1': {
      'policy_fqn': 'db.sch.p1',
      'policy_fqn_key': 'db.sch.p1',
      'columns_key': 'c1'
    },
    'db.sch.extra': {
      'policy_fqn': 'db.sch.extra',
      'policy_fqn_key': 'db.sch.extra',
      'columns_key': 'x'
    }
  } %}

  {% set diff = dbt_snowflake_rap_enforcement.diff_desired_vs_attached(desired, attached) %}
  {{ dbt_unittest.assert_equals(diff.add | length, 1) }}
  {{ dbt_unittest.assert_equals(diff.add[0].policy_fqn, 'db.sch.p2') }}
  {{ dbt_unittest.assert_equals(diff.replace | length, 0) }}
  {{ dbt_unittest.assert_equals(diff.extras | length, 1) }}
  {{ dbt_unittest.assert_equals(diff.extras[0].policy_fqn, 'db.sch.extra') }}

  {% set attached_wrong_cols = {
    'db.sch.p1': {
      'policy_fqn': 'DB.SCH.P1',
      'policy_fqn_key': 'db.sch.p1',
      'columns_key': 'other'
    }
  } %}
  {% set diff2 = dbt_snowflake_rap_enforcement.diff_desired_vs_attached(
    [desired[0]],
    attached_wrong_cols
  ) %}
  {{ dbt_unittest.assert_equals(diff2.replace | length, 1) }}
  {{ dbt_unittest.assert_equals(diff2.add | length, 0) }}
{% endmacro %}
