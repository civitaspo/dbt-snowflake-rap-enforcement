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
      {'mode': 'any', 'fqn': none}
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
      {'mode': 'any', 'fqn': none}
    )
  ) }}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'exact', 'fqn': 'db.sch.p1'}
    )
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.node_satisfies_requirement(
      node_any,
      {'mode': 'exact', 'fqn': 'db.sch.p9'}
    )
  ) }}
{% endmacro %}

{% macro test_get_downstream_requirement_explicit() %}
  {% set upstream = {
    'unique_id': 'model.test.upstream',
    'name': 'upstream',
    'config': {'row_access_policy': 'db.sch.primary on (c1)'},
    'meta': {
      'row_access_policy_enforcement': {
        'enforce_policy': 'explicit',
        'required_policy': 'db.sch.required'
      }
    }
  } %}
  {% set requirement = dbt_snowflake_rap_enforcement.get_downstream_requirement(upstream) %}
  {{ dbt_unittest.assert_equals(requirement.mode, 'exact') }}
  {{ dbt_unittest.assert_equals(requirement.fqn, 'db.sch.required') }}

  {% set inherit_upstream = {
    'unique_id': 'model.test.inherit',
    'name': 'inherit',
    'config': {'row_access_policy': 'db.sch.primary on (c1)'},
    'meta': {
      'row_access_policy_enforcement': {
        'enforce_policy': 'inherit'
      }
    }
  } %}
  {% set inherit_req = dbt_snowflake_rap_enforcement.get_downstream_requirement(inherit_upstream) %}
  {{ dbt_unittest.assert_equals(inherit_req.mode, 'exact') }}
  {{ dbt_unittest.assert_equals(inherit_req.fqn, 'db.sch.primary') }}
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

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.regex_fullmatch('dev|prod', 'dev')
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.regex_fullmatch('dev|prod', 'prod')
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.regex_fullmatch('dev|prod', 'development')
  ) }}
{% endmacro %}

{% macro test_collect_downstream_rap_boundary() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': {
        'unique_id': 'model.test.u',
        'name': 'u',
        'resource_type': 'model',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': {
          'row_access_policy_enforcement': {
            'require_downstream': true,
            'enforce_policy': 'inherit'
          }
        },
        'depends_on': {'nodes': []}
      },
      'model.test.v': {
        'unique_id': 'model.test.v',
        'name': 'v',
        'resource_type': 'model',
        'config': {
          'materialized': 'view',
          'row_access_policy': 'db.sch.other on (c1)'
        },
        'meta': {
          'row_access_policy_enforcement': {
            'require_downstream': false
          }
        },
        'depends_on': {'nodes': ['model.test.u']}
      },
      'model.test.t': {
        'unique_id': 'model.test.t',
        'name': 't',
        'resource_type': 'model',
        'config': {'materialized': 'table'},
        'meta': {},
        'depends_on': {'nodes': ['model.test.v']}
      }
    }
  } %}
  {% set package_vars = {
    'enforce_downstream': true,
    'exclude_resource_types': ['test', 'analysis'],
    'require_materializations': ['table', 'incremental', 'snapshot', 'dynamic_table'],
    'enforce': {
      'selected_only': false,
      'unknown_materialization': 'error'
    },
    'apply': {
      'enabled': false,
      'dry_run': false,
      'selected_only': false,
      'commands': ['run', 'build', 'run-operation']
    }
  } %}
  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_rap_violations(
    graph_context,
    package_vars,
    graph_context.nodes,
    false
  ) %}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 'v') }}
  {{ dbt_unittest.assert_equals(result.violations[0].reason, 'wrong_fqn') }}
{% endmacro %}
