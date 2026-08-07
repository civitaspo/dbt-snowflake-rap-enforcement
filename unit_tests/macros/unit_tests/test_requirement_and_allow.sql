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

{% macro test_matches_allow_without_row_access_policy() %}
  {% set node = {
    'resource_type': 'model',
    'name': 'mart_public_counts',
    'package_name': 'analytics',
    'unique_id': 'model.analytics.mart_public_counts'
  } %}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
      ['mart_public_counts'],
      node
    )
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
      ['other'],
      node
    )
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
      ['mart_.*'],
      node
    )
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
      ['analytics.mart_public_counts'],
      node
    )
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
      ['model.analytics.mart_public_counts'],
      node
    )
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(['*'], node)
  ) }}
  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy('*', node)
  ) }}

  {{ dbt_unittest.assert_true(
    dbt_snowflake_rap_enforcement.regex_fullmatch('dev|prod', 'dev')
  ) }}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.regex_fullmatch('dev|prod', 'development')
  ) }}
{% endmacro %}

{% macro test_collect_downstream_row_access_policy_boundary() %}
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
            'allow_without_row_access_policy': ['*']
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
    'exclude_resource_types': ['test', 'analysis'],
    'passthrough_materializations': ['view', 'ephemeral'],
    'apply_authoritatively': true
  } %}
  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph_context,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 'v') }}
  {{ dbt_unittest.assert_equals(result.violations[0].reason, 'wrong_fqn') }}
{% endmacro %}

{% macro _global_enforcement_meta(allow_without=none) %}
  {# Simulates dbt_project.yml +meta.row_access_policy_enforcement after merge. #}
  {% set enforcement = {
    'enforce_policy': 'inherit'
  } %}
  {% if allow_without is not none %}
    {% do enforcement.update({'allow_without_row_access_policy': allow_without}) %}
  {% endif %}
  {{ return({'row_access_policy_enforcement': enforcement}) }}
{% endmacro %}

{% macro test_global_meta_enforcement_use_cases() %}
  {% set package_vars = {
    'exclude_resource_types': ['test', 'analysis'],
    'passthrough_materializations': ['view', 'ephemeral'],
    'apply_authoritatively': true
  } %}
  {% set global_allow_all = _global_enforcement_meta(['*']) %}
  {% set global_no_allow = _global_enforcement_meta([]) %}

  {# Case 1: model without row_access_policy is never an enforcement source,
     even when project-level enforcement meta is present. #}
  {% set plain = {
    'unique_id': 'model.test.plain_no_rap',
    'name': 'plain_no_rap',
    'resource_type': 'model',
    'config': {'materialized': 'table'},
    'meta': global_allow_all,
    'depends_on': {'nodes': []}
  } %}
  {{ dbt_unittest.assert_false(
    dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(plain)
  ) }}
  {% set case1_graph = {
    'nodes': {
      'model.test.plain_no_rap': plain,
      'model.test.plain_child': {
        'unique_id': 'model.test.plain_child',
        'name': 'plain_child',
        'resource_type': 'model',
        'config': {'materialized': 'table'},
        'meta': global_allow_all,
        'depends_on': {'nodes': ['model.test.plain_no_rap']}
      }
    }
  } %}
  {% set case1 = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    case1_graph,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(case1.violations | length, 0) }}
  {{ dbt_unittest.assert_equals(case1.checked, 0) }}

  {# Case 2: RAP + allow_without_row_access_policy: ["*"] does not flag
     unprotected (or further) downstream terminals for that upstream. #}
  {% set case2_graph = {
    'nodes': {
      'model.test.open_upstream': {
        'unique_id': 'model.test.open_upstream',
        'name': 'open_upstream',
        'resource_type': 'model',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': global_allow_all,
        'depends_on': {'nodes': []}
      },
      'model.test.open_plain': {
        'unique_id': 'model.test.open_plain',
        'name': 'open_plain',
        'resource_type': 'model',
        'config': {'materialized': 'table'},
        'meta': global_allow_all,
        'depends_on': {'nodes': ['model.test.open_upstream']}
      },
      'model.test.open_grandchild': {
        'unique_id': 'model.test.open_grandchild',
        'name': 'open_grandchild',
        'resource_type': 'model',
        'config': {'materialized': 'table'},
        'meta': global_allow_all,
        'depends_on': {'nodes': ['model.test.open_plain']}
      }
    }
  } %}
  {% set case2 = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    case2_graph,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(case2.violations | length, 0) }}

  {# Case 3: after a later RAP model clears allow_without (empty list),
     validation resumes for that model's descendants. #}
  {% set case3_graph = {
    'nodes': {
      'model.test.open_upstream': {
        'unique_id': 'model.test.open_upstream',
        'name': 'open_upstream',
        'resource_type': 'model',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': global_allow_all,
        'depends_on': {'nodes': []}
      },
      'model.test.strict_mid': {
        'unique_id': 'model.test.strict_mid',
        'name': 'strict_mid',
        'resource_type': 'model',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': global_no_allow,
        'depends_on': {'nodes': ['model.test.open_upstream']}
      },
      'model.test.strict_leaf': {
        'unique_id': 'model.test.strict_leaf',
        'name': 'strict_leaf',
        'resource_type': 'model',
        'config': {'materialized': 'table'},
        'meta': global_allow_all,
        'depends_on': {'nodes': ['model.test.strict_mid']}
      }
    }
  } %}
  {% set case3 = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    case3_graph,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(case3.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(case3.violations[0].referenced_name, 'strict_mid') }}
  {{ dbt_unittest.assert_equals(case3.violations[0].referencing_name, 'strict_leaf') }}
  {{ dbt_unittest.assert_equals(case3.violations[0].reason, 'missing_row_access_policy') }}
{% endmacro %}
