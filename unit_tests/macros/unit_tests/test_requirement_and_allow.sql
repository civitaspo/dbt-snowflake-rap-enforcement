{% macro test_node_satisfies_requirement() %}
  {% set node_any = {
    'unique_id': 'model.test.a',
    'name': 'a',
    'config': {'row_access_policy': 'db.sch.p1 on (c1)'},
    'meta': {}
  } %}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'any', 'fqns': []}
    )
  ) }}

  {% set node_none = {
    'unique_id': 'model.test.b',
    'name': 'b',
    'config': {},
    'meta': {}
  } %}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_none,
      {'mode': 'any', 'fqns': []}
    )
  ) }}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'one-of', 'fqns': ['db.sch.p1', 'db.sch.p2']}
    )
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'one-of', 'fqns': ['db.sch.p9']}
    )
  ) }}

  {% set node_multi = {
    'unique_id': 'model.test.c',
    'name': 'c',
    'config': {'row_access_policy': 'db.sch.p1 on (c1)'},
    'meta': {
      'row_access_policy_enforcement': {
        'additional_row_access_policies': ['db.sch.p2 on (c2)']
      }
    }
  } %}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_multi,
      {'mode': 'all', 'fqns': ['db.sch.p1', 'db.sch.p2']}
    )
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'all', 'fqns': ['db.sch.p1', 'db.sch.p2']}
    )
  ) }}
{% endmacro %}

{% macro test_matches_allow_without_rap() %}
  {% set node = {
    'resource_type': 'model',
    'name': 'mart_public_counts',
    'database': 'analytics',
    'schema': 'mart',
    'identifier': 'mart_public_counts',
    'package_name': 'layerone',
    'tags': ['public']
  } %}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_rap(
      [{'resource_type': 'model', 'name': 'mart_public_counts'}],
      node
    )
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.matches_allow_without_rap(
      [{'resource_type': 'model', 'name': 'other'}],
      node
    )
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_rap(['*'], node)
  ) }}
{% endmacro %}
