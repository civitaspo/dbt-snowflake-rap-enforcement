{% macro is_apply_relation_node(node) %}
  {# Physical model/snapshot relation (not ephemeral). #}
  {% set resource_type = node.get('resource_type', '') %}
  {% if resource_type not in ['model', 'snapshot'] %}
    {{ return(false) }}
  {% endif %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_materialized(node) %}
  {% if materialized in ['ephemeral'] %}
    {{ return(false) }}
  {% endif %}
  {{ return(true) }}
{% endmacro %}

{% macro is_apply_eligible_node(node, apply_authoritatively=true) %}
  {#
    Nodes considered for apply:
    - Always: model/snapshot with row_access_policy declared
    - When apply_authoritatively: also model/snapshot without RAP so stale
      attachments can be dropped when config clears the policy
  #}
  {% if not dbt_snowflake_rap_enforcement.is_apply_relation_node(node) %}
    {{ return(false) }}
  {% endif %}
  {% if dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(node) %}
    {{ return(true) }}
  {% endif %}
  {{ return(apply_authoritatively) }}
{% endmacro %}

{% macro resolve_apply_target_node_ids(selected_resources, which, graph_node_ids) %}
  {#
    run/build/snapshot/retry: current selection only (empty => no targets).
    run-operation: dbt often puts the operation itself in selected_resources,
    which is not an apply target — always use the project graph instead.
  #}
  {% if which == 'run-operation' %}
    {{ return(graph_node_ids) }}
  {% endif %}
  {% if selected_resources is not none and selected_resources | length > 0 %}
    {{ return(selected_resources) }}
  {% endif %}
  {{ return([]) }}
{% endmacro %}

{% macro collect_row_access_policy_target_nodes(apply_authoritatively=true) %}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return([]) }}
  {% endif %}

  {% set which = 'run-operation' %}
  {% if flags is defined and flags.WHICH is defined and flags.WHICH is not none %}
    {% set which = flags.WHICH | string | trim | lower %}
  {% endif %}

  {% set selected = none %}
  {% if selected_resources is defined and selected_resources is not none %}
    {% set selected = selected_resources %}
  {% endif %}

  {% set graph_node_ids = [] %}
  {% if which == 'run-operation' %}
    {% for node_id in graph.nodes %}
      {% do graph_node_ids.append(node_id) %}
    {% endfor %}
  {% endif %}

  {% set node_ids = dbt_snowflake_rap_enforcement.resolve_apply_target_node_ids(
    selected,
    which,
    graph_node_ids
  ) %}

  {% set targets = [] %}
  {% for node_id in node_ids %}
    {% set node = graph.nodes.get(node_id) %}
    {% if node and dbt_snowflake_rap_enforcement.is_apply_eligible_node(node, apply_authoritatively) %}
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
