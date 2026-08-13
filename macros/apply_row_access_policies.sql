{#
  Apply the configured row access policy to selected model/snapshot relations.

  Snowflake allows one RAP per relation. When apply_authoritatively=true
  (default), attached policies that differ from config are replaced, and
  attachments are dropped when row_access_policy is cleared from config.

  Runs for dbt commands: run, build, snapshot, retry, run-operation.
  Info logs only for run, build, run-operation (inventory metrics plus one
    line per alter: model, current attachment, ALTER SQL). compile is a
    silent no-op. Attachments are loaded by desired policy name first, then
    relation-scoped POLICY_REFERENCES in bounded batches for RAP-declared
    targets missing from that index.
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

  {% set targets = dbt_snowflake_rap_enforcement.collect_row_access_policy_target_nodes(
    package_vars.apply_authoritatively
  ) %}
  {% if targets | length == 0 %}
    {% if emit_info %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "No selected row access policy targets to apply"
      ) }}
    {% endif %}
    {{ return('') }}
  {% endif %}

  {% set grouped = dbt_snowflake_rap_enforcement.group_targets_by_database(targets) %}
  {% set ns = namespace(
    applied=0,
    skipped_missing=0,
    left_mismatches=0,
    bulk_policies=0,
    fallback_relations=0,
    fallback_batches=0,
    attachment_rows=0,
    planned_actions=0
  ) %}

  {% for database, db_targets in grouped.items() %}
    {% set schemas = [] %}
    {% set identifiers = [] %}
    {% set schema_seen = {} %}
    {% set identifier_seen = {} %}
    {% for target_node in db_targets %}
      {% set schema_key = target_node.schema | string %}
      {% if schema_key not in schema_seen %}
        {% do schema_seen.update({schema_key: true}) %}
        {% do schemas.append(target_node.schema) %}
      {% endif %}
      {% set identifier_key = target_node.identifier | string %}
      {% if identifier_key not in identifier_seen %}
        {% do identifier_seen.update({identifier_key: true}) %}
        {% do identifiers.append(target_node.identifier) %}
      {% endif %}
    {% endfor %}

    {# Relations first: POLICY_REFERENCES errors if the object does not exist. #}
    {% set relations_sql = dbt_snowflake_rap_enforcement.build_existing_relations_sql(
      database,
      schemas,
      identifiers
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

    {% set desired_policies = dbt_snowflake_rap_enforcement.collect_desired_policy_fqns(db_targets) %}
    {% set ns.bulk_policies = ns.bulk_policies + (desired_policies | length) %}
    {% set bulk_sql = dbt_snowflake_rap_enforcement.build_policy_references_by_policies_sql(
      desired_policies,
      database
    ) %}
    {% set bulk_rows = [] %}
    {% if bulk_sql is not none %}
      {% set bulk_result = run_query(bulk_sql) %}
      {% if bulk_result is not none %}
        {% set bulk_rows = bulk_result.rows %}
      {% endif %}
    {% endif %}
    {% set ns.attachment_rows = ns.attachment_rows + (bulk_rows | length) %}
    {% set bulk_attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(
      dbt_snowflake_rap_enforcement.attachment_maps_from_query_rows(bulk_rows)
    ) %}

    {% set fallback_targets = dbt_snowflake_rap_enforcement.select_attachment_fallback_targets(
      db_targets,
      relations,
      bulk_attachments
    ) %}
    {% set ns.fallback_relations = ns.fallback_relations + (fallback_targets | length) %}
    {% set fallback_sqls = dbt_snowflake_rap_enforcement.build_policy_references_sql_batches(
      database,
      fallback_targets,
      package_vars.policy_references_chunk_size
    ) %}
    {% set ns.fallback_batches = ns.fallback_batches + (fallback_sqls | length) %}
    {% set fallback_maps = [] %}
    {% for fallback_sql in fallback_sqls %}
      {% set fallback_result = run_query(fallback_sql) %}
      {% set fallback_rows = [] %}
      {% if fallback_result is not none %}
        {% set fallback_rows = fallback_result.rows %}
      {% endif %}
      {% set ns.attachment_rows = ns.attachment_rows + (fallback_rows | length) %}
      {% for row_map in dbt_snowflake_rap_enforcement.attachment_maps_from_query_rows(fallback_rows) %}
        {% do fallback_maps.append(row_map) %}
      {% endfor %}
    {% endfor %}
    {% set attachments = dbt_snowflake_rap_enforcement.merge_attachment_indexes(
      bulk_attachments,
      dbt_snowflake_rap_enforcement.index_policy_attachments(fallback_maps)
    ) %}
    {% set plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
      db_targets,
      relations,
      attachments,
      package_vars.apply_authoritatively
    ) %}
    {% set ns.planned_actions = ns.planned_actions + (plan.actions | length) %}
    {% if emit_info %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "apply_row_access_policies inventory for "
        ~ database
        ~ ": targets="
        ~ (db_targets | length)
        ~ ", bulk_policies="
        ~ (desired_policies | length)
        ~ ", fallback_relations="
        ~ (fallback_targets | length)
        ~ ", fallback_batches="
        ~ (fallback_sqls | length)
        ~ ", attachment_rows="
        ~ ((bulk_rows | length) + (fallback_maps | length))
        ~ ", planned_actions="
        ~ (plan.actions | length)
        ~ ", missing_relations="
        ~ (plan.skipped_missing | length)
      ) }}
    {% endif %}

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
      {% set desired_display = '(none)' %}
      {% if mismatch.desired is not none %}
        {% set desired_display = mismatch.desired.policy_fqn %}
      {% endif %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "WARNING: leaving mismatched row access policy on "
        ~ mismatch.rel_key
        ~ " (apply_authoritatively=false); desired="
        ~ desired_display
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
      {% elif action.action == 'drop' %}
        {% set sql = dbt_snowflake_rap_enforcement.alter_drop_row_access_policy_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
          action.existing_policy_fqn,
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
            ~ "; desired=none; "
            ~ sql
          ) }}
        {% endif %}
        {% do run_query(sql) %}
        {% set ns.applied = ns.applied + 1 %}
      {% elif action.action == 'drop_all' %}
        {% set sql = dbt_snowflake_rap_enforcement.alter_drop_all_row_access_policies_sql(
          existing.database,
          existing.schema,
          existing.identifier,
          existing.table_type,
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
            ~ "]; desired=none; "
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

  {% if emit_info %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      "apply_row_access_policies complete: targets="
      ~ (targets | length)
      ~ ", bulk_policies="
      ~ ns.bulk_policies
      ~ ", fallback_relations="
      ~ ns.fallback_relations
      ~ ", fallback_batches="
      ~ ns.fallback_batches
      ~ ", attachment_rows="
      ~ ns.attachment_rows
      ~ ", planned_actions="
      ~ ns.planned_actions
      ~ ", applied="
      ~ ns.applied
      ~ ", missing_relations="
      ~ ns.skipped_missing
    ) }}
  {% endif %}
  {{ return('') }}
{% endmacro %}
