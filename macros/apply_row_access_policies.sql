{#
  Apply configured row access policies to existing relations.

  Wire from the root project:

    on-run-end:
      - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"

  Or run manually:

    dbt run-operation apply_row_access_policies
#}
{% macro apply_row_access_policies() %}
  {{ return(adapter.dispatch('apply_row_access_policies', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__apply_row_access_policies() %}
  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}
  {% if not package_vars.apply.enabled %}
    {{ log("dbt_snowflake_rap_enforcement.apply.enabled is false; skipping RAP apply", info=true) }}
    {{ return('') }}
  {% endif %}

  {% if target.type != 'snowflake' %}
    {{ log(
      "dbt_snowflake_rap_enforcement.apply_row_access_policies skipped on adapter '"
      ~ target.type
      ~ "' (Snowflake only)",
      info=true
    ) }}
    {{ return('') }}
  {% endif %}

  {% set targets = dbt_snowflake_rap_enforcement.collect_rap_target_nodes(
    selected_only=package_vars.apply.selected_only
  ) %}
  {% if targets | length == 0 %}
    {{ log("No RAP targets to apply", info=true) }}
    {{ return('') }}
  {% endif %}

  {% set grouped = dbt_snowflake_rap_enforcement.group_targets_by_database(targets) %}
  {% set ns = namespace(applied=0, skipped_missing=0, warnings=0) %}

  {% for database, db_targets in grouped.items() %}
    {% set policy_fqns = [] %}
    {% set schemas = [] %}
    {% for target_node in db_targets %}
      {% if target_node.schema not in schemas %}
        {% do schemas.append(target_node.schema) %}
      {% endif %}
      {% for desired in target_node.desired %}
        {% if desired.policy_fqn not in policy_fqns %}
          {% do policy_fqns.append(desired.policy_fqn) %}
        {% endif %}
      {% endfor %}
    {% endfor %}

    {% set attachments_sql = dbt_snowflake_rap_enforcement.build_policy_references_sql(database, policy_fqns) %}
    {% set relations_sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(database, schemas) %}

    {% set attachment_rows = [] %}
    {% if attachments_sql is not none %}
      {% set attachment_result = run_query(attachments_sql) %}
      {% if attachment_result is not none %}
        {% set attachment_rows = attachment_result.rows %}
      {% endif %}
    {% endif %}

    {% set relation_rows = [] %}
    {% if relations_sql is not none %}
      {% set relation_result = run_query(relations_sql) %}
      {% if relation_result is not none %}
        {% set relation_rows = relation_result.rows %}
      {% endif %}
    {% endif %}

    {# Normalize adapter rows into mappings for indexing helpers. #}
    {% set attachment_maps = [] %}
    {% for row in attachment_rows %}
      {% do attachment_maps.append({
        'ref_database': row[0],
        'ref_schema': row[1],
        'ref_entity_name': row[2],
        'policy_fqn_key': row[3],
        'columns_key': row[4],
        'policy_fqn': row[5]
      }) %}
    {% endfor %}
    {% set relation_maps = [] %}
    {% for row in relation_rows %}
      {% do relation_maps.append({
        'table_catalog': row[0],
        'table_schema': row[1],
        'table_name': row[2],
        'table_type': row[3]
      }) %}
    {% endfor %}

    {% set attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(attachment_maps) %}
    {% set relations = dbt_snowflake_rap_enforcement.index_existing_relations(relation_maps) %}

    {% for target_node in db_targets %}
      {% set rel_key = (
        (target_node.database | string | upper)
        ~ '.'
        ~ (target_node.schema | string | upper)
        ~ '.'
        ~ (target_node.identifier | string | upper)
      ) %}
      {% set existing = relations.get(rel_key) %}
      {% if existing is none %}
        {% set ns.skipped_missing = ns.skipped_missing + 1 %}
      {% else %}
        {% set attached = attachments.get(rel_key, {}) %}
        {% set diff = dbt_snowflake_rap_enforcement.diff_desired_vs_attached(
          target_node.desired,
          attached
        ) %}

        {% for extra in diff.extras %}
          {% set ns.warnings = ns.warnings + 1 %}
          {{ log(
            "WARNING: relation "
            ~ rel_key
            ~ " has unmanaged row access policy "
            ~ extra.policy_fqn
            ~ " (not dropped)",
            info=true
          ) }}
        {% endfor %}

        {% for desired in diff.add %}
          {% set sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
            existing.database,
            existing.schema,
            existing.identifier,
            existing.table_type,
            desired.policy_fqn,
            desired.columns_sql
          ) %}
          {% if package_vars.apply.dry_run %}
            {{ log("DRY RUN: " ~ sql, info=true) }}
          {% else %}
            {% do run_query(sql) %}
          {% endif %}
          {% set ns.applied = ns.applied + 1 %}
        {% endfor %}

        {% for item in diff.replace %}
          {% set sql = dbt_snowflake_rap_enforcement.alter_drop_add_row_access_policy_sql(
            existing.database,
            existing.schema,
            existing.identifier,
            existing.table_type,
            item.existing_policy_fqn,
            item.desired.policy_fqn,
            item.desired.columns_sql
          ) %}
          {% if package_vars.apply.dry_run %}
            {{ log("DRY RUN: " ~ sql, info=true) }}
          {% else %}
            {% do run_query(sql) %}
          {% endif %}
          {% set ns.applied = ns.applied + 1 %}
        {% endfor %}
      {% endif %}
    {% endfor %}
  {% endfor %}

  {{ log(
    "RAP apply finished: statements="
    ~ ns.applied
    ~ ", missing_relations_skipped="
    ~ ns.skipped_missing
    ~ ", unmanaged_policy_warnings="
    ~ ns.warnings
    ~ (", dry_run=true" if package_vars.apply.dry_run else ""),
    info=true
  ) }}
  {{ return('') }}
{% endmacro %}
