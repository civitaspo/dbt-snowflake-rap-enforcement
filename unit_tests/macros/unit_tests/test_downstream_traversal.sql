{% macro _traversal_package_vars() %}
  {{ return({
    'exclude_resource_types': ['test', 'analysis'],
    'passthrough_materializations': ['view', 'ephemeral'],
    'apply_authoritatively': true
  }) }}
{% endmacro %}

{% macro _traversal_node(
  unique_id,
  name,
  materialized='table',
  depends_on=none,
  row_access_policy=none,
  meta=none,
  resource_type='model',
  package_name='test'
) %}
  {% set config = {'materialized': materialized} %}
  {% if row_access_policy is not none %}
    {% do config.update({'row_access_policy': row_access_policy}) %}
  {% endif %}
  {{ return({
    'unique_id': unique_id,
    'name': name,
    'resource_type': resource_type,
    'package_name': package_name,
    'config': config,
    'meta': meta if meta is not none else {},
    'depends_on': {'nodes': depends_on if depends_on is not none else []}
  }) }}
{% endmacro %}

{# Test-only copy of the pre-index walker. Do not use in production macros. #}
{% macro collect_downstream_from_ancestor__legacy(ancestor_id, graph_context, package_vars, visited) %}
  {% if ancestor_id in visited %}
    {{ return([]) }}
  {% endif %}
  {% do visited.append(ancestor_id) %}

  {% set collected = [] %}
  {% for node_id, node in graph_context.nodes.items() %}
    {% set depends_on = node.get('depends_on', {}) %}
    {% set ref_nodes = depends_on.get('nodes', []) %}
    {% if ancestor_id in ref_nodes %}
      {% if dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(node) %}
        {% do collected.append({'node': node, 'via': 'row_access_policy_boundary'}) %}
      {% elif dbt_snowflake_rap_enforcement.is_passthrough_materialization(
        node,
        package_vars.passthrough_materializations
      ) %}
        {% set nested = collect_downstream_from_ancestor__legacy(
          node_id,
          graph_context,
          package_vars,
          visited
        ) %}
        {% for item in nested %}
          {% do collected.append(item) %}
        {% endfor %}
      {% elif dbt_snowflake_rap_enforcement.is_model_or_snapshot(node) %}
        {% do collected.append({'node': node, 'via': 'terminal'}) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(collected) }}
{% endmacro %}

{% macro collect_downstream_row_access_policy_violations__legacy(graph_context, package_vars) %}
  {% set violations = [] %}
  {% set checks = namespace(total=0) %}
  {% set seen_check_keys = [] %}
  {% set seen_violation_keys = [] %}

  {% for node_id, upstream in graph_context.nodes.items() %}
    {% if dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(upstream) %}
      {% set requirement = dbt_snowflake_rap_enforcement.get_downstream_requirement(upstream) %}
      {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream) %}
      {% set allow_rules = enforcement.get('allow_without_row_access_policy') %}
      {% set visited = [] %}
      {% set candidates = collect_downstream_from_ancestor__legacy(
        node_id,
        graph_context,
        package_vars,
        visited
      ) %}

      {% for item in candidates %}
        {% set terminal = item.node %}
        {% set terminal_id = terminal.unique_id %}
        {% set referencing_type = terminal.get('resource_type', '') %}
        {% if referencing_type not in package_vars.exclude_resource_types %}
          {% set check_key = terminal_id ~ '||' ~ node_id %}
          {% if check_key not in seen_check_keys %}
            {% do seen_check_keys.append(check_key) %}
            {% set checks.total = checks.total + 1 %}
          {% endif %}

          {% set ok = dbt_snowflake_rap_enforcement.node_satisfies_requirement(terminal, requirement) %}
          {% set allowed = dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
            allow_rules,
            terminal
          ) %}
          {% if (not ok) and (not allowed) %}
            {% if check_key not in seen_violation_keys %}
              {% do seen_violation_keys.append(check_key) %}
              {% set reason = 'missing_row_access_policy' %}
              {% if dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(terminal) %}
                {% set reason = 'wrong_fqn' %}
              {% endif %}
              {% do violations.append({
                'referencing_id': terminal_id,
                'referencing_name': terminal.get('name', terminal_id),
                'referenced_id': node_id,
                'referenced_name': upstream.get('name', node_id),
                'reason': reason,
                'requirement': requirement.display
              }) %}
            {% endif %}
          {% endif %}
        {% endif %}
      {% endfor %}
    {% endif %}
  {% endfor %}

  {{ return({'violations': violations, 'checked': checks.total}) }}
{% endmacro %}

{% macro _assert_violation_results_equal(actual, expected, label) %}
  {{ dbt_unittest.assert_equals(actual.checked, expected.checked) }}
  {{ dbt_unittest.assert_equals(actual.violations | length, expected.violations | length) }}
  {% for violation in actual.violations %}
    {% set other = expected.violations[loop.index0] %}
    {{ dbt_unittest.assert_equals(violation.referencing_id, other.referencing_id) }}
    {{ dbt_unittest.assert_equals(violation.referencing_name, other.referencing_name) }}
    {{ dbt_unittest.assert_equals(violation.referenced_id, other.referenced_id) }}
    {{ dbt_unittest.assert_equals(violation.referenced_name, other.referenced_name) }}
    {{ dbt_unittest.assert_equals(violation.reason, other.reason) }}
    {{ dbt_unittest.assert_equals(violation.requirement, other.requirement) }}
  {% endfor %}
{% endmacro %}

{% macro _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {% set legacy = collect_downstream_row_access_policy_violations__legacy(
    graph_context,
    package_vars
  ) %}
  {% set indexed = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph_context,
    package_vars
  ) %}
  {{ _assert_violation_results_equal(indexed, legacy, 'indexed vs legacy') }}
  {{ return(indexed) }}
{% endmacro %}

{% macro _inherit_meta(allow_without=none) %}
  {% set enforcement = {'enforce_policy': 'inherit'} %}
  {% if allow_without is not none %}
    {% do enforcement.update({'allow_without_row_access_policy': allow_without}) %}
  {% endif %}
  {{ return({'row_access_policy_enforcement': enforcement}) }}
{% endmacro %}

{% macro build_scale_downstream_graph(rap_count, terminal_count) %}
  {# Inline node dicts: a per-node helper call at N=15,000 is too slow in Jinja. #}
  {% set nodes = {} %}
  {% set allow_all = {
    'row_access_policy_enforcement': {
      'enforce_policy': 'inherit',
      'allow_without_row_access_policy': ['*']
    }
  } %}
  {% set empty_meta = {} %}
  {% set empty_deps = [] %}
  {% for i in range(rap_count) %}
    {% set source_id = 'model.test.source_' ~ i %}
    {% do nodes.update({
      source_id: {
        'unique_id': source_id,
        'name': 'source_' ~ i,
        'resource_type': 'model',
        'package_name': 'test',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': allow_all,
        'depends_on': {'nodes': empty_deps}
      }
    }) %}
    {% set view_id = 'model.test.view_' ~ i %}
    {% do nodes.update({
      view_id: {
        'unique_id': view_id,
        'name': 'view_' ~ i,
        'resource_type': 'model',
        'package_name': 'test',
        'config': {'materialized': 'view'},
        'meta': empty_meta,
        'depends_on': {'nodes': [source_id]}
      }
    }) %}
  {% endfor %}
  {% for i in range(terminal_count) %}
    {% set terminal_id = 'model.test.terminal_' ~ i %}
    {% do nodes.update({
      terminal_id: {
        'unique_id': terminal_id,
        'name': 'terminal_' ~ i,
        'resource_type': 'model',
        'package_name': 'test',
        'config': {'materialized': 'table'},
        'meta': empty_meta,
        'depends_on': {
          'nodes': [
            'model.test.view_' ~ i,
            'model.test.view_' ~ (i + terminal_count)
          ]
        }
      }
    }) %}
  {% endfor %}
  {{ return({'nodes': nodes}) }}
{% endmacro %}

{% macro build_shared_tail_downstream_graph(rap_count, terminal_count, allow_all=true) %}
  {% set nodes = {} %}
  {% set enforcement = {'enforce_policy': 'inherit'} %}
  {% if allow_all %}
    {% do enforcement.update({'allow_without_row_access_policy': ['*']}) %}
  {% else %}
    {% do enforcement.update({'allow_without_row_access_policy': []}) %}
  {% endif %}
  {% set meta = {'row_access_policy_enforcement': enforcement} %}
  {% set empty_meta = {} %}
  {% set empty_deps = [] %}
  {% set view_id = 'model.test.shared_view' %}
  {% for i in range(rap_count) %}
    {% set source_id = 'model.test.source_' ~ i %}
    {% do nodes.update({
      source_id: {
        'unique_id': source_id,
        'name': 'source_' ~ i,
        'resource_type': 'model',
        'package_name': 'test',
        'config': {
          'materialized': 'table',
          'row_access_policy': 'db.sch.p on (c1)'
        },
        'meta': meta,
        'depends_on': {'nodes': empty_deps}
      }
    }) %}
  {% endfor %}
  {% set view_deps = [] %}
  {% for i in range(rap_count) %}
    {% do view_deps.append('model.test.source_' ~ i) %}
  {% endfor %}
  {% do nodes.update({
    view_id: {
      'unique_id': view_id,
      'name': 'shared_view',
      'resource_type': 'model',
      'package_name': 'test',
      'config': {'materialized': 'view'},
      'meta': empty_meta,
      'depends_on': {'nodes': view_deps}
    }
  }) %}
  {% for i in range(terminal_count) %}
    {% set terminal_id = 'model.test.terminal_' ~ i %}
    {% do nodes.update({
      terminal_id: {
        'unique_id': terminal_id,
        'name': 'terminal_' ~ i,
        'resource_type': 'model',
        'package_name': 'test',
        'config': {'materialized': 'table'},
        'meta': empty_meta,
        'depends_on': {'nodes': [view_id]}
      }
    }) %}
  {% endfor %}
  {{ return({'nodes': nodes}) }}
{% endmacro %}

{% macro test_downstream_adjacency_discovery_order() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)'
      ),
      'model.test.t2': _traversal_node('model.test.t2', 't2', 'table', ['model.test.u']),
      'model.test.t1': _traversal_node('model.test.t1', 't1', 'table', ['model.test.u'])
    }
  } %}
  {% set index = dbt_snowflake_rap_enforcement.build_downstream_graph_index(
    graph_context,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(index.graph_nodes, 3) }}
  {{ dbt_unittest.assert_equals(index.rap_sources, 1) }}
  {{ dbt_unittest.assert_equals(index.dependency_edges, 2) }}
  {{ dbt_unittest.assert_equals(
    index.children_by_parent.get('model.test.u'),
    ['model.test.t2', 'model.test.t1']
  ) }}
{% endmacro %}

{% macro test_downstream_direct_unprotected_terminal() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.u'])
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 1) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 't') }}
  {{ dbt_unittest.assert_equals(result.violations[0].reason, 'missing_row_access_policy') }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 1) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 1) }}
{% endmacro %}

{% macro test_downstream_sibling_manifest_order() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.t2': _traversal_node('model.test.t2', 't2', 'table', ['model.test.u']),
      'model.test.t1': _traversal_node('model.test.t1', 't1', 'table', ['model.test.u'])
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 2) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 2) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 't2') }}
  {{ dbt_unittest.assert_equals(result.violations[1].referencing_name, 't1') }}
{% endmacro %}

{% macro test_downstream_passthrough_chain() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.v': _traversal_node('model.test.v', 'v', 'view', ['model.test.u']),
      'model.test.e': _traversal_node('model.test.e', 'e', 'ephemeral', ['model.test.v']),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.e'])
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 't') }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 3) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 3) }}
{% endmacro %}

{% macro test_downstream_diamond_dedup() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.v': _traversal_node('model.test.v', 'v', 'view', ['model.test.u']),
      'model.test.t': _traversal_node(
        'model.test.t',
        't',
        'table',
        ['model.test.u', 'model.test.v']
      )
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 1) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_id, 'model.test.t') }}
{% endmacro %}

{% macro test_downstream_rap_boundary_and_existing_cases() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set boundary_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.v': _traversal_node(
        'model.test.v',
        'v',
        'view',
        ['model.test.u'],
        'db.sch.other on (c1)',
        _inherit_meta(['*'])
      ),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.v'])
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(boundary_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 'v') }}
  {{ dbt_unittest.assert_equals(result.violations[0].reason, 'wrong_fqn') }}

  {% set global_allow_all = _inherit_meta(['*']) %}
  {% set global_no_allow = _inherit_meta([]) %}
  {% set case1_graph = {
    'nodes': {
      'model.test.plain_no_rap': _traversal_node(
        'model.test.plain_no_rap',
        'plain_no_rap',
        'table',
        [],
        none,
        global_allow_all
      ),
      'model.test.plain_child': _traversal_node(
        'model.test.plain_child',
        'plain_child',
        'table',
        ['model.test.plain_no_rap'],
        none,
        global_allow_all
      )
    }
  } %}
  {% set case1 = _assert_indexed_matches_legacy(case1_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(case1.checked, 0) }}

  {% set case2_graph = {
    'nodes': {
      'model.test.open_upstream': _traversal_node(
        'model.test.open_upstream',
        'open_upstream',
        'table',
        [],
        'db.sch.p on (c1)',
        global_allow_all
      ),
      'model.test.open_plain': _traversal_node(
        'model.test.open_plain',
        'open_plain',
        'table',
        ['model.test.open_upstream'],
        none,
        global_allow_all
      ),
      'model.test.open_grandchild': _traversal_node(
        'model.test.open_grandchild',
        'open_grandchild',
        'table',
        ['model.test.open_plain'],
        none,
        global_allow_all
      )
    }
  } %}
  {% set case2 = _assert_indexed_matches_legacy(case2_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(case2.violations | length, 0) }}

  {% set case3_graph = {
    'nodes': {
      'model.test.open_upstream': _traversal_node(
        'model.test.open_upstream',
        'open_upstream',
        'table',
        [],
        'db.sch.p on (c1)',
        global_allow_all
      ),
      'model.test.strict_mid': _traversal_node(
        'model.test.strict_mid',
        'strict_mid',
        'table',
        ['model.test.open_upstream'],
        'db.sch.p on (c1)',
        global_no_allow
      ),
      'model.test.strict_leaf': _traversal_node(
        'model.test.strict_leaf',
        'strict_leaf',
        'table',
        ['model.test.strict_mid'],
        none,
        global_allow_all
      )
    }
  } %}
  {% set case3 = _assert_indexed_matches_legacy(case3_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(case3.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(case3.violations[0].referenced_name, 'strict_mid') }}
  {{ dbt_unittest.assert_equals(case3.violations[0].referencing_name, 'strict_leaf') }}
{% endmacro %}

{% macro test_downstream_excluded_and_mixed_resources() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'test.test.t_test': _traversal_node(
        'test.test.t_test',
        't_test',
        'test',
        ['model.test.u'],
        none,
        {},
        'test'
      ),
      'analysis.test.t_analysis': _traversal_node(
        'analysis.test.t_analysis',
        't_analysis',
        'view',
        ['model.test.u'],
        none,
        {},
        'analysis'
      ),
      'snapshot.test.t_snap': _traversal_node(
        'snapshot.test.t_snap',
        't_snap',
        'snapshot',
        ['model.test.u'],
        none,
        {},
        'snapshot'
      )
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 1) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_id, 'snapshot.test.t_snap') }}
{% endmacro %}

{% macro test_downstream_requirement_modes() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set inherit_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p1 on (c1)',
        _inherit_meta()
      ),
      'model.test.t': _traversal_node(
        'model.test.t',
        't',
        'table',
        ['model.test.u'],
        'db.sch.p2 on (c1)'
      )
    }
  } %}
  {% set inherit_result = _assert_indexed_matches_legacy(inherit_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(inherit_result.violations[0].reason, 'wrong_fqn') }}
  {{ dbt_unittest.assert_equals(inherit_result.violations[0].requirement, 'inherit db.sch.p1') }}

  {% set any_meta = {'row_access_policy_enforcement': {'enforce_policy': 'any'}} %}
  {% set any_ok_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p1 on (c1)',
        any_meta
      ),
      'model.test.t': _traversal_node(
        'model.test.t',
        't',
        'table',
        ['model.test.u'],
        'db.sch.other on (c1)'
      )
    }
  } %}
  {% set any_ok = _assert_indexed_matches_legacy(any_ok_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(any_ok.violations | length, 0) }}
  {{ dbt_unittest.assert_equals(any_ok.checked, 1) }}

  {% set any_missing_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p1 on (c1)',
        any_meta
      ),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.u'])
    }
  } %}
  {% set any_missing = _assert_indexed_matches_legacy(any_missing_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(any_missing.violations[0].reason, 'missing_row_access_policy') }}

  {% set explicit_meta = {
    'row_access_policy_enforcement': {
      'enforce_policy': 'explicit',
      'required_policy': 'db.sch.required'
    }
  } %}
  {% set explicit_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p1 on (c1)',
        explicit_meta
      ),
      'model.test.t': _traversal_node(
        'model.test.t',
        't',
        'table',
        ['model.test.u'],
        'db.sch.p1 on (c1)'
      )
    }
  } %}
  {% set explicit_result = _assert_indexed_matches_legacy(explicit_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(explicit_result.violations[0].reason, 'wrong_fqn') }}
  {{ dbt_unittest.assert_equals(explicit_result.violations[0].requirement, 'explicit db.sch.required') }}
{% endmacro %}

{% macro test_downstream_allow_rules() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set exact_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta(['allowed_plain'])
      ),
      'model.test.allowed_plain': _traversal_node(
        'model.test.allowed_plain',
        'allowed_plain',
        'table',
        ['model.test.u']
      ),
      'model.test.other': _traversal_node('model.test.other', 'other', 'table', ['model.test.u'])
    }
  } %}
  {% set exact = _assert_indexed_matches_legacy(exact_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(exact.checked, 2) }}
  {{ dbt_unittest.assert_equals(exact.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(exact.violations[0].referencing_name, 'other') }}

  {% set regex_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta(['mart_.*'])
      ),
      'model.test.mart_public': _traversal_node(
        'model.test.mart_public',
        'mart_public',
        'table',
        ['model.test.u']
      ),
      'model.test.core_x': _traversal_node('model.test.core_x', 'core_x', 'table', ['model.test.u'])
    }
  } %}
  {% set regex = _assert_indexed_matches_legacy(regex_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(regex.violations | length, 1) }}
  {{ dbt_unittest.assert_equals(regex.violations[0].referencing_name, 'core_x') }}

  {% set star_graph = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta(['*'])
      ),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.u'])
    }
  } %}
  {% set star = _assert_indexed_matches_legacy(star_graph, package_vars) %}
  {{ dbt_unittest.assert_equals(star.checked, 1) }}
  {{ dbt_unittest.assert_equals(star.violations | length, 0) }}
{% endmacro %}

{% macro test_downstream_passthrough_cycle() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = {
    'nodes': {
      'model.test.u': _traversal_node(
        'model.test.u',
        'u',
        'table',
        [],
        'db.sch.p on (c1)',
        _inherit_meta()
      ),
      'model.test.a': _traversal_node(
        'model.test.a',
        'a',
        'view',
        ['model.test.u', 'model.test.c']
      ),
      'model.test.b': _traversal_node('model.test.b', 'b', 'view', ['model.test.a']),
      'model.test.c': _traversal_node('model.test.c', 'c', 'view', ['model.test.b']),
      'model.test.t': _traversal_node('model.test.t', 't', 'table', ['model.test.c'])
    }
  } %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 1) }}
  {{ dbt_unittest.assert_equals(result.violations[0].referencing_name, 't') }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 4) }}
{% endmacro %}

{% macro test_downstream_node_facts_and_metrics_format() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set node = _traversal_node(
    'model.test.u',
    'u',
    'view',
    [],
    'db.sch.p on (c1)'
  ) %}
  {% set facts = dbt_snowflake_rap_enforcement.classify_downstream_node(node, package_vars) %}
  {{ dbt_unittest.assert_true(facts.has_rap) }}
  {{ dbt_unittest.assert_true(facts.is_model_or_snapshot) }}
  {{ dbt_unittest.assert_true(facts.is_passthrough) }}

  {% set line = dbt_snowflake_rap_enforcement.format_downstream_check_metrics({
    'checked': 6,
    'stats': {
      'graph_nodes': 15,
      'rap_sources': 2,
      'dependency_edges': 4,
      'ancestor_visits': 3,
      'child_edges_examined': 4
    }
  }) %}
  {{ dbt_unittest.assert_equals(
    line,
    'Downstream row access policy check metrics: graph_nodes=15; rap_sources=2; dependency_edges=4; ancestor_visits=3; child_edges_examined=4; checked=6'
  ) }}
{% endmacro %}

{% macro test_downstream_scale_downscaled_matches_legacy() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = build_scale_downstream_graph(6, 3) %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.stats.graph_nodes, 15) }}
  {{ dbt_unittest.assert_equals(result.stats.rap_sources, 6) }}
  {{ dbt_unittest.assert_equals(result.stats.dependency_edges, 12) }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 12) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 12) }}
  {{ dbt_unittest.assert_equals(result.checked, 6) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 0) }}
{% endmacro %}

{% macro test_downstream_shared_tail_matches_legacy() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = build_shared_tail_downstream_graph(2, 1, false) %}
  {% set result = _assert_indexed_matches_legacy(graph_context, package_vars) %}
  {{ dbt_unittest.assert_equals(result.checked, 2) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 2) }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 3) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 3) }}
{% endmacro %}

{% macro test_downstream_shared_tail_complexity() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set rap_count = 200 %}
  {% set terminal_count = 50 %}
  {% set graph_context = build_shared_tail_downstream_graph(rap_count, terminal_count, true) %}
  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph_context,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(result.stats.graph_nodes, 251) }}
  {{ dbt_unittest.assert_equals(result.stats.rap_sources, 200) }}
  {{ dbt_unittest.assert_equals(result.stats.dependency_edges, 250) }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 201) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 250) }}
  {{ dbt_unittest.assert_equals(result.checked, 10000) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 0) }}
  {{ dbt_unittest.assert_true(
    result.stats.child_edges_examined < (rap_count * terminal_count)
  ) }}
{% endmacro %}

{% macro test_downstream_scale_N15000_R6000_complexity() %}
  {% set package_vars = _traversal_package_vars() %}
  {% set graph_context = build_scale_downstream_graph(6000, 3000) %}
  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph_context,
    package_vars
  ) %}
  {{ dbt_unittest.assert_equals(result.stats.graph_nodes, 15000) }}
  {{ dbt_unittest.assert_equals(result.stats.rap_sources, 6000) }}
  {{ dbt_unittest.assert_equals(result.stats.dependency_edges, 12000) }}
  {{ dbt_unittest.assert_equals(result.stats.ancestor_visits, 12000) }}
  {{ dbt_unittest.assert_equals(result.stats.child_edges_examined, 12000) }}
  {{ dbt_unittest.assert_equals(result.checked, 6000) }}
  {{ dbt_unittest.assert_equals(result.violations | length, 0) }}
{% endmacro %}
