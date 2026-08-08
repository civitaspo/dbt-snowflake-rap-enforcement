{#
  Apply the configured row access policy to selected model/snapshot relations.

  Snowflake allows one RAP per relation. When apply_authoritatively=true
  (default), attached policies that differ from config are dropped and replaced.

  Runs for dbt commands: run, build, snapshot, retry, run-operation.
  Info logs only for run, build, run-operation (one line per alter:
  model, current attachment, ALTER SQL). compile is a silent no-op.
  On run/build/snapshot/retry, targets are the current selection. On
  run-operation, selected_resources is empty, so eligible nodes from the
  project graph are used instead.

  Identifier assumption: unquoted Snowflake identifiers (case-insensitive).
  Case-sensitive / quote_identifiers relations are not supported.

  Wire from the root project:

    on-run-end:
      - "{{ dbt_snowflake_rap_enforcement.apply_row_access_policies() }}"
#}
{% macro apply_row_access_policies() %}
  {{ return(adapter.dispatch('apply_row_access_policies', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__apply_row_access_policies() %}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {# Apply may run on snapshot/retry too; info logs only for these commands. #}
  {% set allowed_commands = ['run', 'build', 'snapshot', 'retry', 'run-operation'] %}
  {% set info_log_commands = ['run', 'build', 'run-operation'] %}
  {% set which = '' %}
  {% if flags is defined and flags.WHICH is defined and flags.WHICH is not none %}
    {% set which = flags.WHICH | string | trim | lower %}
  {% endif %}
  {# compile / parse / docs / etc.: silent no-op (no info logs). #}
  {% if which not in allowed_commands %}
    {{ return('') }}
  {% endif %}
  {% set emit_info = which in info_log_commands %}

  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}

  {% if target.type != 'snowflake' %}
    {% if emit_info %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "apply_row_access_policies skipped on adapter '"
        ~ target.type
        ~ "' (Snowflake only)"
      ) }}
    {% endif %}
    {{ return('') }}
  {% endif %}

  {% set targets = dbt_snowflake_rap_enforcement.collect_row_access_policy_target_nodes() %}
  {% if targets | length == 0 %}
    {% if emit_info %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "No selected row access policy targets to apply"
      ) }}
    {% endif %}
    {{ return('') }}
  {% endif %}

  {% set grouped = dbt_snowflake_rap_enforcement.group_targets_by_database(targets) %}
  {% set ns = namespace(applied=0, skipped_missing=0, left_mismatches=0) %}

  {% for database, db_targets in grouped.items() %}
    {% set schemas = [] %}
    {% for target_node in db_targets %}
      {% if target_node.schema not in schemas %}
        {% do schemas.append(target_node.schema) %}
      {% endif %}
    {% endfor %}

    {# Relations first: POLICY_REFERENCES errors if the object does not exist. #}
    {% set relations_sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
      database,
      schemas
    ) %}
    {% set relation_rows = [] %}
    {% if relations_sql is not none %}
      {% set relation_result = run_query(relations_sql) %}
      {% if relation_result is not none %}
        {% set relation_rows = relation_result.rows %}
      {% endif %}
    {% endif %}

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
    {% set relations = dbt_snowflake_rap_enforcement.index_existing_relations(relation_maps) %}

    {% set attachment_targets = [] %}
    {% for target_node in db_targets %}
      {% set rel_key = (
        (target_node.database | string | upper)
        ~ '.'
        ~ (target_node.schema | string | upper)
        ~ '.'
        ~ (target_node.identifier | string | upper)
      ) %}
      {% if rel_key in relations %}
        {% do attachment_targets.append({
          'schema': target_node.schema,
          'identifier': target_node.identifier,
          'domain': target_node.domain
        }) %}
      {% endif %}
    {% endfor %}

    {% set attachments_sql = dbt_snowflake_rap_enforcement.build_policy_references_sql(
      database,
      attachment_targets
    ) %}
    {% set attachment_rows = [] %}
    {% if attachments_sql is not none %}
      {% set attachment_result = run_query(attachments_sql) %}
      {% if attachment_result is not none %}
        {% set attachment_rows = attachment_result.rows %}
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

    {% set attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(attachment_maps) %}
    {% set plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
      db_targets,
      relations,
      attachments,
      package_vars.apply_authoritatively
    ) %}

    {% for missing in plan.skipped_missing %}
      {% set ns.skipped_missing = ns.skipped_missing + 1 %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "WARNING: skipping missing relation "
        ~ missing.rel_key
        ~ " for "
        ~ missing.unique_id
      ) }}
    {% endfor %}

    {% for mismatch in plan.left_mismatches %}
      {% set ns.left_mismatches = ns.left_mismatches + 1 %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "WARNING: leaving mismatched row access policy on "
        ~ mismatch.rel_key
        ~ " (apply_authoritatively=false); desired="
        ~ mismatch.desired.policy_fqn
        ~ ", attached="
        ~ (mismatch.existing_policy_fqn if mismatch.existing_policy_fqn is not none else '(multiple or unknown)')
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
        {% if emit_info %}
          {{ dbt_snowflake_rap_enforcement.package_log(
            "Row access policy apply "
            ~ action.unique_id
            ~ " on "
            ~ action.rel_key
            ~ ": current=none; "
            ~ sql
          ) }}
        {% endif %}
        {% do run_query(sql) %}
        {% set ns.applied = ns.applied + 1 %}
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
        {% if emit_info %}
          {{ dbt_snowflake_rap_enforcement.package_log(
            "Row access policy apply "
            ~ action.unique_id
            ~ " on "
            ~ action.rel_key
            ~ ": current="
            ~ action.existing_policy_fqn
            ~ "; "
            ~ sql
          ) }}
        {% endif %}
        {% do run_query(sql) %}
        {% set ns.applied = ns.applied + 1 %}
      {% else %}
        {# replace_all: DROP ALL and ADD are separate Snowflake statements. #}
        {% set drop_sql = dbt_snowflake_rap_enforcement.alter_drop_all_row_access_policies_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          existing.is_dynamic
        ) %}
        {% set add_sql = dbt_snowflake_rap_enforcement.alter_add_row_access_policy_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          desired.policy_fqn,
          desired.columns_sql,
          existing.is_dynamic
        ) %}
        {% if emit_info %}
          {{ dbt_snowflake_rap_enforcement.package_log(
            "Row access policy apply "
            ~ action.unique_id
            ~ " on "
            ~ action.rel_key
            ~ ": current=["
            ~ action.existing_policy_fqn
            ~ "]; "
            ~ drop_sql
            ~ "; "
            ~ add_sql
          ) }}
        {% endif %}
        {% do run_query(drop_sql) %}
        {% do run_query(add_sql) %}
        {% set ns.applied = ns.applied + 2 %}
      {% endif %}
    {% endfor %}
  {% endfor %}
  {{ return('') }}
{% endmacro %}
