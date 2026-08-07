{% macro is_optional_materialization(node, optional_materializations) %}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type == 'snapshot' %}
    {{ return('snapshot' in optional_materializations) }}
  {% endif %}
  {% if resource_type != 'model' %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {{ return(materialized in optional_materializations) }}
{% endmacro %}

{% macro is_enforced_materialization(node, enforced_materializations) %}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type == 'snapshot' %}
    {{ return('snapshot' in enforced_materializations) }}
  {% endif %}
  {% if resource_type != 'model' %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {{ return(materialized in enforced_materializations) }}
{% endmacro %}

{% macro node_satisfies_requirement(node, requirement) %}
  {% set declared = dbt_snowflake_rap_enforcement.get_declared_policy_fqn(node) %}
  {% if requirement.mode == 'any' %}
    {{ return(declared is not none) }}
  {% else %}
    {{ return(declared is not none and declared == requirement.fqn) }}
  {% endif %}
{% endmacro %}

{% macro collect_downstream_from_ancestor(ancestor_id, graph_context, package_vars, visited) %}
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
      {% elif dbt_snowflake_rap_enforcement.is_optional_materialization(
        node,
        package_vars.optional_materializations
      ) %}
        {% set nested = dbt_snowflake_rap_enforcement.collect_downstream_from_ancestor(
          node_id,
          graph_context,
          package_vars,
          visited
        ) %}
        {% for item in nested %}
          {% do collected.append(item) %}
        {% endfor %}
      {% elif dbt_snowflake_rap_enforcement.is_enforced_materialization(
        node,
        package_vars.enforced_materializations
      ) %}
        {% do collected.append({'node': node, 'via': 'terminal'}) %}
      {% elif package_vars.unknown_materialization == 'error' %}
        {% do collected.append({'node': node, 'via': 'unknown_materialization'}) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(collected) }}
{% endmacro %}

{% macro collect_downstream_row_access_policy_violations(graph_context, package_vars) %}
  {% set violations = [] %}
  {% set checks = namespace(total=0) %}
  {% set seen_check_keys = [] %}
  {% set seen_violation_keys = [] %}

  {% for node_id, upstream in graph_context.nodes.items() %}
    {% if dbt_snowflake_rap_enforcement.enforce_downstream_enabled(upstream) %}
      {% set requirement = dbt_snowflake_rap_enforcement.get_downstream_requirement(upstream) %}
      {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream) %}
      {% set allow_rules = enforcement.get('allow_without_row_access_policy') %}
      {% set visited = [] %}
      {% set candidates = dbt_snowflake_rap_enforcement.collect_downstream_from_ancestor(
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

          {% set ok = false %}
          {% if item.via == 'unknown_materialization' %}
            {% set ok = false %}
          {% else %}
            {% set ok = dbt_snowflake_rap_enforcement.node_satisfies_requirement(terminal, requirement) %}
          {% endif %}
          {% set allowed = dbt_snowflake_rap_enforcement.matches_allow_without_row_access_policy(
            allow_rules,
            terminal
          ) %}
          {% if (not ok) and (not allowed) %}
            {% if check_key not in seen_violation_keys %}
              {% do seen_violation_keys.append(check_key) %}
              {% set reason = item.via %}
              {% if item.via == 'terminal' and not dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(terminal) %}
                {% set reason = 'missing_row_access_policy' %}
              {% elif item.via in ['terminal', 'row_access_policy_boundary'] %}
                {% set reason = 'wrong_fqn' if dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(terminal) else 'missing_row_access_policy' %}
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
