{% macro is_model_or_snapshot(node) %}
  {{ return(node.get('resource_type', '') in ['model', 'snapshot']) }}
{% endmacro %}

{% macro is_passthrough_materialization(node, passthrough_materializations) %}
  {% if not dbt_snowflake_rap_enforcement.is_model_or_snapshot(node) %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) | string | lower %}
  {{ return(materialized in passthrough_materializations) }}
{% endmacro %}

{% macro node_satisfies_requirement(node, requirement) %}
  {% set declared = dbt_snowflake_rap_enforcement.get_declared_policy_fqn(node) %}
  {% if requirement.mode == 'any' %}
    {{ return(declared is not none) }}
  {% else %}
    {{ return(declared is not none and declared == requirement.fqn) }}
  {% endif %}
{% endmacro %}

{% macro classify_downstream_node(node, package_vars) %}
  {{ return({
    'node': node,
    'resource_type': node.get('resource_type', ''),
    'has_rap': dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(node),
    'is_model_or_snapshot': dbt_snowflake_rap_enforcement.is_model_or_snapshot(node),
    'is_passthrough': dbt_snowflake_rap_enforcement.is_passthrough_materialization(
      node,
      package_vars.passthrough_materializations
    )
  }) }}
{% endmacro %}

{% macro build_downstream_graph_index(graph_context, package_vars) %}
  {#
    One manifest-order pass. Child lists append in graph.nodes iteration
    order so indexed DFS matches the previous full-scan discovery order.
  #}
  {% set children_by_parent = {} %}
  {% set node_facts = {} %}
  {% set counters = namespace(graph_nodes=0, dependency_edges=0, rap_sources=0) %}

  {% for node_id, node in graph_context.nodes.items() %}
    {% set counters.graph_nodes = counters.graph_nodes + 1 %}
    {% set facts = dbt_snowflake_rap_enforcement.classify_downstream_node(node, package_vars) %}
    {% do node_facts.update({node_id: facts}) %}
    {% if facts.has_rap %}
      {% set counters.rap_sources = counters.rap_sources + 1 %}
    {% endif %}

    {% set depends_on = node.get('depends_on', {}) %}
    {% set ref_nodes = depends_on.get('nodes', []) %}
    {% if ref_nodes is none %}
      {% set ref_nodes = [] %}
    {% endif %}
    {% for parent_id in ref_nodes %}
      {% set counters.dependency_edges = counters.dependency_edges + 1 %}
      {% set children = children_by_parent.get(parent_id, []) %}
      {% do children.append(node_id) %}
      {% do children_by_parent.update({parent_id: children}) %}
    {% endfor %}
  {% endfor %}

  {{ return({
    'children_by_parent': children_by_parent,
    'node_facts': node_facts,
    'graph_nodes': counters.graph_nodes,
    'rap_sources': counters.rap_sources,
    'dependency_edges': counters.dependency_edges
  }) }}
{% endmacro %}

{% macro collect_passthrough_frontier(
  ancestor_id,
  children_by_parent,
  node_facts,
  frontier_cache,
  computing,
  stats=none
) %}
  {#
    Isolated frontier of one passthrough node. Cached so RAP sources that
    share a downstream view do not re-walk that subtree.
  #}
  {% if ancestor_id in frontier_cache %}
    {{ return(frontier_cache.get(ancestor_id)) }}
  {% endif %}
  {% if ancestor_id in computing %}
    {{ return([]) }}
  {% endif %}
  {% do computing.update({ancestor_id: true}) %}
  {% if stats is not none %}
    {% set stats.ancestor_visits = stats.ancestor_visits + 1 %}
  {% endif %}

  {% set collected = dbt_snowflake_rap_enforcement.collect_child_candidates(
    ancestor_id,
    children_by_parent,
    node_facts,
    frontier_cache,
    computing,
    stats
  ) %}
  {% do frontier_cache.update({ancestor_id: collected}) %}
  {{ return(collected) }}
{% endmacro %}

{% macro collect_child_candidates(
  ancestor_id,
  children_by_parent,
  node_facts,
  frontier_cache,
  computing,
  stats=none
) %}
  {% set collected = [] %}
  {% for child_id in children_by_parent.get(ancestor_id, []) %}
    {% if stats is not none %}
      {% set stats.child_edges_examined = stats.child_edges_examined + 1 %}
    {% endif %}
    {% set facts = node_facts.get(child_id) %}
    {% if facts is none %}
      {# Missing graph entry: skip, same as an unmatched full-scan node. #}
    {% elif facts.has_rap %}
      {% do collected.append({'node': facts.node, 'via': 'row_access_policy_boundary'}) %}
    {% elif facts.is_passthrough %}
      {% set nested = dbt_snowflake_rap_enforcement.collect_passthrough_frontier(
        child_id,
        children_by_parent,
        node_facts,
        frontier_cache,
        computing,
        stats
      ) %}
      {% for item in nested %}
        {% do collected.append(item) %}
      {% endfor %}
    {% elif facts.is_model_or_snapshot %}
      {# Non-passthrough model/snapshot: enforcement terminal. #}
      {% do collected.append({'node': facts.node, 'via': 'terminal'}) %}
    {% endif %}
  {% endfor %}
  {{ return(collected) }}
{% endmacro %}

{% macro collect_downstream_from_ancestor(
  ancestor_id,
  children_by_parent,
  node_facts,
  visited,
  stats=none,
  frontier_cache=none,
  computing=none
) %}
  {% if ancestor_id in visited %}
    {{ return([]) }}
  {% endif %}
  {% do visited.update({ancestor_id: true}) %}
  {% if stats is not none %}
    {% set stats.ancestor_visits = stats.ancestor_visits + 1 %}
  {% endif %}
  {% set cache = frontier_cache if frontier_cache is not none else {} %}
  {% set in_progress = computing if computing is not none else {} %}

  {{ return(dbt_snowflake_rap_enforcement.collect_child_candidates(
    ancestor_id,
    children_by_parent,
    node_facts,
    cache,
    in_progress,
    stats
  )) }}
{% endmacro %}

{% macro collect_downstream_row_access_policy_violations(graph_context, package_vars, stats=none) %}
  {% set index = dbt_snowflake_rap_enforcement.build_downstream_graph_index(
    graph_context,
    package_vars
  ) %}
  {% set walk_stats = namespace(
    graph_nodes=index.graph_nodes,
    rap_sources=index.rap_sources,
    dependency_edges=index.dependency_edges,
    ancestor_visits=0,
    child_edges_examined=0
  ) %}

  {% set violations = [] %}
  {% set checks = namespace(total=0) %}
  {% set frontier_cache = {} %}
  {% set computing = {} %}

  {% for node_id, upstream in graph_context.nodes.items() %}
    {% set upstream_facts = index.node_facts.get(node_id) %}
    {% if upstream_facts is not none and upstream_facts.has_rap %}
      {% set requirement = dbt_snowflake_rap_enforcement.get_downstream_requirement(upstream) %}
      {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream) %}
      {% set allow_rules = enforcement.get('allow_without_row_access_policy') %}
      {% set visited = {} %}
      {% set seen_terminals = {} %}
      {% set candidates = dbt_snowflake_rap_enforcement.collect_downstream_from_ancestor(
        node_id,
        index.children_by_parent,
        index.node_facts,
        visited,
        walk_stats,
        frontier_cache,
        computing
      ) %}

      {% for item in candidates %}
        {% set terminal = item.node %}
        {% set terminal_id = terminal.unique_id %}
        {% set referencing_type = terminal.get('resource_type', '') %}
        {% if referencing_type not in package_vars.exclude_resource_types %}
          {% if terminal_id not in seen_terminals %}
            {% do seen_terminals.update({terminal_id: true}) %}
            {% set checks.total = checks.total + 1 %}

            {% set ok = dbt_snowflake_rap_enforcement.node_satisfies_requirement(terminal, requirement) %}
            {% set allowed = dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
              allow_rules,
              terminal
            ) %}
            {% if (not ok) and (not allowed) %}
              {% set reason = 'missing_row_access_policy' %}
              {% set terminal_facts = index.node_facts.get(terminal_id) %}
              {% if terminal_facts is not none and terminal_facts.has_rap %}
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

  {% if stats is not none %}
    {% set stats.graph_nodes = walk_stats.graph_nodes %}
    {% set stats.rap_sources = walk_stats.rap_sources %}
    {% set stats.dependency_edges = walk_stats.dependency_edges %}
    {% set stats.ancestor_visits = walk_stats.ancestor_visits %}
    {% set stats.child_edges_examined = walk_stats.child_edges_examined %}
  {% endif %}

  {{ return({
    'violations': violations,
    'checked': checks.total,
    'stats': {
      'graph_nodes': walk_stats.graph_nodes,
      'rap_sources': walk_stats.rap_sources,
      'dependency_edges': walk_stats.dependency_edges,
      'ancestor_visits': walk_stats.ancestor_visits,
      'child_edges_examined': walk_stats.child_edges_examined
    }
  }) }}
{% endmacro %}
