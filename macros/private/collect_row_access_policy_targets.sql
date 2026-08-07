{% macro is_apply_eligible_node(node) %}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type not in ['model', 'snapshot'] %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {% if materialized in ['ephemeral'] %}
    {{ return(false) }}
  {% endif %}
  {{ return(dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(node)) }}
{% endmacro %}

{% macro collect_row_access_policy_target_nodes() %}
  {#
    Apply targets are always limited to the current dbt selection.
    Empty/undefined selection => no targets (fail closed).
  #}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return([]) }}
  {% endif %}
  {% if selected_resources is not defined or selected_resources is none or selected_resources | length == 0 %}
    {{ return([]) }}
  {% endif %}

  {% set targets = [] %}
  {% for node_id in selected_resources %}
    {% set node = graph.nodes.get(node_id) %}
    {% if node and dbt_snowflake_rap_enforcement.is_apply_eligible_node(node) %}
      {% set desired = dbt_snowflake_rap_enforcement.get_desired_policy_entry(node) %}
      {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
      {% do targets.append({
        'unique_id': node_id,
        'name': node.get('name', node_id),
        'database': node.get('database'),
        'schema': node.get('schema'),
        'identifier': node.get('alias') or node.get('identifier') or node.get('name'),
        'materialized': materialized,
        'domain': dbt_snowflake_rap_enforcement.ref_entity_domain_for_materialized(materialized),
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
        "Row access policy target is missing database: " ~ target.unique_id
      ) }}
    {% endif %}
    {% set db_key = database | string | upper %}
    {% if db_key not in grouped %}
      {% do grouped.update({db_key: []}) %}
    {% endif %}
    {% do grouped[db_key].append(target) %}
  {% endfor %}
  {{ return(grouped) }}
{% endmacro %}
