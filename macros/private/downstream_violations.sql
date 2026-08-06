{% macro is_passthrough_materialization(node) %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {{ return(materialized in ['view', 'ephemeral']) }}
{% endmacro %}

{% macro is_physical_required_node(node, require_materializations) %}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type == 'snapshot' %}
    {{ return('snapshot' in require_materializations) }}
  {% endif %}
  {% if resource_type != 'model' %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {{ return(materialized in require_materializations) }}
{% endmacro %}

{% macro node_satisfies_requirement(node, requirement) %}
  {% set declared = dbt_snowflake_rap_enforcement.get_declared_policy_fqns(node) %}
  {% if requirement.mode == 'any' %}
    {{ return(declared | length > 0) }}
  {% elif requirement.mode == 'one-of' %}
    {% for fqn in declared %}
      {% if fqn in requirement.fqns %}
        {{ return(true) }}
      {% endif %}
    {% endfor %}
    {{ return(false) }}
  {% else %}
    {% if requirement.fqns | length == 0 %}
      {{ return(true) }}
    {% endif %}
    {% for required_fqn in requirement.fqns %}
      {% if required_fqn not in declared %}
        {{ return(false) }}
      {% endif %}
    {% endfor %}
    {{ return(true) }}
  {% endif %}
{% endmacro %}

{% macro collect_downstream_from_ancestor(ancestor_id, graph_context, require_materializations, visited) %}
  {% if ancestor_id in visited %}
    {{ return([]) }}
  {% endif %}
  {% do visited.append(ancestor_id) %}

  {% set collected = [] %}
  {% for node_id, node in graph_context.nodes.items() %}
    {% set depends_on = node.get('depends_on', {}) %}
    {% set ref_nodes = depends_on.get('nodes', []) %}
    {% if ancestor_id in ref_nodes %}
      {% if dbt_snowflake_rap_enforcement.node_has_rap_declaration(node) %}
        {% if dbt_snowflake_rap_enforcement.is_physical_required_node(node, require_materializations) %}
          {% do collected.append({'node': node, 'via': 'rap_node'}) %}
        {% endif %}
        {# Stop passthrough: this node owns further downstream policy. #}
      {% elif dbt_snowflake_rap_enforcement.is_passthrough_materialization(node) %}
        {% set nested = dbt_snowflake_rap_enforcement.collect_downstream_from_ancestor(
          node_id,
          graph_context,
          require_materializations,
          visited
        ) %}
        {% for item in nested %}
          {% do collected.append(item) %}
        {% endfor %}
      {% elif dbt_snowflake_rap_enforcement.is_physical_required_node(node, require_materializations) %}
        {% do collected.append({'node': node, 'via': 'passthrough'}) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(collected) }}
{% endmacro %}

{% macro collect_downstream_rap_violations(graph_context, package_vars, nodes_to_check, selected_only=false) %}
  {% set violations = [] %}
  {% set checks = namespace(total=0) %}
  {% set seen_violation_keys = [] %}

  {% for node_id, upstream in graph_context.nodes.items() %}
    {% if dbt_snowflake_rap_enforcement.require_downstream_enabled(upstream) %}
      {% set requirement = dbt_snowflake_rap_enforcement.get_required_policy_fqns(upstream) %}
      {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream) %}
      {% set allow_rules = enforcement.get('allow_without_rap') %}
      {% set visited = [] %}
      {% set candidates = dbt_snowflake_rap_enforcement.collect_downstream_from_ancestor(
        node_id,
        graph_context,
        package_vars.require_materializations,
        visited
      ) %}

      {% for item in candidates %}
        {% set terminal = item.node %}
        {% set terminal_id = terminal.unique_id %}
        {% set in_scope = (not selected_only) or (terminal_id in nodes_to_check) %}
        {% if in_scope %}
          {% set referencing_type = terminal.get('resource_type', '') %}
          {% if referencing_type not in package_vars.exclude_resource_types %}
            {% set checks.total = checks.total + 1 %}
            {% set ok = dbt_snowflake_rap_enforcement.node_satisfies_requirement(terminal, requirement) %}
            {% set allowed = dbt_snowflake_rap_enforcement.matches_allow_without_rap(allow_rules, terminal) %}
            {% if (not ok) and (not allowed) %}
              {% set vkey = terminal_id ~ '||' ~ node_id %}
              {% if vkey not in seen_violation_keys %}
                {% do seen_violation_keys.append(vkey) %}
                {% do violations.append({
                  'referencing_id': terminal_id,
                  'referencing_name': terminal.get('name', terminal_id),
                  'referenced_id': node_id,
                  'referenced_name': upstream.get('name', node_id),
                  'reason': item.via,
                  'requirement': requirement
                }) %}
              {% endif %}
            {% endif %}
          {% endif %}
        {% endif %}
      {% endfor %}
    {% endif %}
  {% endfor %}

  {{ return({'violations': violations, 'checked': checks.total}) }}
{% endmacro %}
