{% macro is_apply_eligible_node(node) %}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type not in ['model', 'snapshot'] %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {% if materialized in ['ephemeral'] %}
    {{ return(false) }}
  {% endif %}
  {{ return(dbt_snowflake_rap_enforcement.node_has_rap_declaration(node)) }}
{% endmacro %}

{% macro collect_rap_target_nodes(selected_only=false) %}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return([]) }}
  {% endif %}

  {% set nodes_to_scan = {} %}
  {% if selected_only and selected_resources is defined and selected_resources is not none and selected_resources | length > 0 %}
    {% for node_id in selected_resources %}
      {% set node = graph.nodes.get(node_id) %}
      {% if node %}
        {% do nodes_to_scan.update({node_id: node}) %}
      {% endif %}
    {% endfor %}
  {% else %}
    {% set nodes_to_scan = graph.nodes %}
  {% endif %}

  {% set targets = [] %}
  {% for node_id, node in nodes_to_scan.items() %}
    {% if dbt_snowflake_rap_enforcement.is_apply_eligible_node(node) %}
      {% set desired = dbt_snowflake_rap_enforcement.get_desired_policy_entries(node) %}
      {% do targets.append({
        'unique_id': node_id,
        'name': node.get('name', node_id),
        'database': node.get('database'),
        'schema': node.get('schema'),
        'identifier': node.get('alias') or node.get('identifier') or node.get('name'),
        'desired': desired
      }) %}
    {% endif %}
  {% endfor %}
  {{ return(targets) }}
{% endmacro %}

{% macro group_targets_by_database(targets) %}
  {% set grouped = {} %}
  {% for target in targets %}
    {% set database = target.database %}
    {% if database is none or (database | string | length) == 0 %}
      {{ exceptions.raise_compiler_error(
        "RAP target is missing database: " ~ target.unique_id
      ) }}
    {% endif %}
    {% set db_key = database | string %}
    {% if db_key not in grouped %}
      {% do grouped.update({db_key: []}) %}
    {% endif %}
    {% do grouped[db_key].append(target) %}
  {% endfor %}
  {{ return(grouped) }}
{% endmacro %}
