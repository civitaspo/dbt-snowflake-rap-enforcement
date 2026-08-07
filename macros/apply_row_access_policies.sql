{#
  Apply the configured row access policy to selected model/snapshot relations.

  Snowflake allows one RAP per relation. When apply_authoritatively=true
  (default), attached policies that differ from config are dropped and replaced.

  Runs only for dbt commands: run, build, run-operation.
  Targets are always the current selection (no full-graph apply option).

  Wire from the root project:

    on-run-end:
      - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"
#}
{% macro apply_row_access_policies() %}
  {{ return(adapter.dispatch('apply_row_access_policies', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__apply_row_access_policies() %}
  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}

  {% if target.type != 'snowflake' %}
    {{ log(
      "dbt_snowflake_rap_enforcement.apply_row_access_policies skipped on adapter '"
      ~ target.type
      ~ "' (Snowflake only)",
      info=true
    ) }}
    {{ return('') }}
  {% endif %}

  {% set allowed_commands = ['run', 'build', 'run-operation'] %}
  {% set which = 'run-operation' %}
  {% if flags is defined and flags.WHICH is defined and flags.WHICH is not none %}
    {% set which = flags.WHICH | string | trim | lower %}
  {% endif %}
  {% if which not in allowed_commands %}
    {{ log(
      "dbt_snowflake_rap_enforcement.apply skipped for command '"
      ~ which
      ~ "' (allowed: "
      ~ allowed_commands | join(', ')
      ~ ")",
      info=true
    ) }}
    {{ return('') }}
  {% endif %}

  {% set targets = dbt_snowflake_rap_enforcement.collect_row_access_policy_target_nodes() %}
  {% if targets | length == 0 %}
    {{ log("No selected row access policy targets to apply", info=true) }}
    {{ return('') }}
  {% endif %}

  {% set grouped = dbt_snowflake_rap_enforcement.group_targets_by_database(targets) %}
  {% set ns = namespace(applied=0, skipped_missing=0, left_mismatches=0) %}

  {% for database, db_targets in grouped.items() %}
    {% set schemas = [] %}
    {% set attachment_targets = [] %}
    {% for target_node in db_targets %}
      {% if target_node.schema not in schemas %}
        {% do schemas.append(target_node.schema) %}
      {% endif %}
      {% do attachment_targets.append({
        'schema': target_node.schema,
        'identifier': target_node.identifier,
        'domain': target_node.domain
      }) %}
    {% endfor %}

    {% set attachments_sql = dbt_snowflake_rap_enforcement.build_policy_references_sql(
      database,
      attachment_targets
    ) %}
    {% set relations_sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
      database,
      schemas
    ) %}

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
        'table_type': row[3],
        'is_dynamic': row[4] if row | length > 4 else 'NO'
      }) %}
    {% endfor %}

    {% set attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(attachment_maps) %}
    {% set relations = dbt_snowflake_rap_enforcement.index_existing_relations(relation_maps) %}
    {% set plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
      db_targets,
      relations,
      attachments,
      package_vars.apply_authoritatively
    ) %}

    {% for missing in plan.skipped_missing %}
      {% set ns.skipped_missing = ns.skipped_missing + 1 %}
      {{ log(
        "WARNING: skipping missing relation "
        ~ missing.rel_key
        ~ " for "
        ~ missing.unique_id,
        info=true
      ) }}
    {% endfor %}

    {% for mismatch in plan.left_mismatches %}
      {% set ns.left_mismatches = ns.left_mismatches + 1 %}
      {{ log(
        "WARNING: leaving mismatched row access policy on "
        ~ mismatch.rel_key
        ~ " (apply_authoritatively=false); desired="
        ~ mismatch.desired.policy_fqn
        ~ ", attached="
        ~ mismatch.existing_policy_fqn,
        info=true
      ) }}
    {% endfor %}

    {% for action in plan.actions %}
      {% set existing = action.relation %}
      {% set desired = action.desired %}
      {% if action.action == 'add' %}
        {% set sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          desired.policy_fqn,
          desired.columns_sql,
          existing.is_dynamic
        ) %}
      {% elif action.action == 'replace' %}
        {% set sql = dbt_snowflake_rap_enforcement.alter_drop_add_row_access_policy_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          action.existing_policy_fqn,
          desired.policy_fqn,
          desired.columns_sql,
          existing.is_dynamic
        ) %}
      {% else %}
        {% set sql = dbt_snowflake_rap_enforcement.alter_drop_all_add_row_access_policy_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          desired.policy_fqn,
          desired.columns_sql,
          existing.is_dynamic
        ) %}
      {% endif %}

      {% do run_query(sql) %}
      {% set ns.applied = ns.applied + 1 %}
    {% endfor %}
  {% endfor %}

  {{ log(
    "Row access policy apply finished: statements="
    ~ ns.applied
    ~ ", missing_relations_skipped="
    ~ ns.skipped_missing
    ~ ", left_mismatches="
    ~ ns.left_mismatches
    ~ ", apply_authoritatively="
    ~ package_vars.apply_authoritatively,
    info=true
  ) }}
  {{ return('') }}
{% endmacro %}
