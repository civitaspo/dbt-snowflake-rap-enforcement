{#
  Apply the configured row access policy to selected model/snapshot relations.

  Snowflake allows one RAP per relation. When apply_authoritatively=true
  (default), attached policies that differ from config are replaced, and
  attachments are dropped when row_access_policy is cleared from config.

  Runs for dbt commands: run, build, snapshot, retry, run-operation.
  Info logs for those commands include inventory metrics plus one line per
    alter: model, current attachment, ALTER SQL. compile is a silent no-op.

  Inventory is adaptive. Small selections use relation-scoped
  POLICY_REFERENCES in bounded batches. Large selections use one unique-policy
  lookup for the whole hook, then relation-scoped fallback only for RAP-declared
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

{% macro format_apply_inventory_metrics(metrics) %}
  {{ return(
    "inventory_strategy="
    ~ metrics.inventory_strategy
    ~ "; targets="
    ~ metrics.targets
    ~ "; target_databases="
    ~ metrics.target_databases
    ~ "; policy_lookup_calls="
    ~ metrics.policy_lookup_calls
    ~ "; bulk_attachment_rows="
    ~ metrics.bulk_attachment_rows
    ~ "; selected_attachment_hits="
    ~ metrics.selected_attachment_hits
    ~ "; extra_attachments="
    ~ metrics.extra_attachments
    ~ "; relation_lookup_targets="
    ~ metrics.relation_lookup_targets
    ~ "; relation_lookup_batches="
    ~ metrics.relation_lookup_batches
    ~ "; fallback_relations="
    ~ metrics.fallback_relations
    ~ "; fallback_batches="
    ~ metrics.fallback_batches
    ~ "; planned_actions="
    ~ metrics.planned_actions
    ~ "; applied="
    ~ metrics.applied
    ~ "; missing_relations="
    ~ metrics.missing_relations
  ) }}
{% endmacro %}

{% macro default__apply_row_access_policies() %}
  {% if not execute %}
    {{ return('') }}
  {% endif %}

  {% set allowed_commands = ['run', 'build', 'snapshot', 'retry', 'run-operation'] %}
  {% set which = '' %}
  {% if flags is defined and flags.WHICH is defined and flags.WHICH is not none %}
    {% set which = flags.WHICH | string | trim | lower %}
  {% endif %}
  {# compile / parse / docs / etc.: silent no-op (no info logs). #}
  {% if which not in allowed_commands %}
    {{ return('') }}
  {% endif %}

  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}

  {% if target.type != 'snowflake' %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      "apply_row_access_policies skipped on adapter '"
      ~ target.type
      ~ "' (Snowflake only)"
    ) }}
    {{ return('') }}
  {% endif %}

  {% set targets = dbt_snowflake_rap_enforcement.collect_row_access_policy_target_nodes(
    package_vars.apply_authoritatively
  ) %}
  {% if targets | length == 0 %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      "No selected row access policy targets to apply"
    ) }}
    {{ return('') }}
  {% endif %}

  {% set grouped = dbt_snowflake_rap_enforcement.group_targets_by_database(targets) %}
  {% set target_databases = dbt_snowflake_rap_enforcement.collect_target_database_names(targets) %}
  {% set target_key_index = dbt_snowflake_rap_enforcement.build_target_relation_key_index(targets) %}
  {% set strategy = dbt_snowflake_rap_enforcement.choose_policy_reference_inventory_strategy(
    targets | length,
    package_vars.policy_references_relation_threshold
  ) %}
  {% set ns = namespace(
    applied=0,
    skipped_missing=0,
    left_mismatches=0,
    policy_lookup_calls=0,
    bulk_attachment_rows=0,
    selected_attachment_hits=0,
    extra_attachments=0,
    relation_lookup_targets=0,
    relation_lookup_batches=0,
    fallback_relations=0,
    fallback_batches=0,
    planned_actions=0,
    bulk_maps_by_database={}
  ) %}

  {% if strategy == 'policy' %}
    {% set desired_policies = dbt_snowflake_rap_enforcement.collect_desired_policy_fqns(targets) %}
    {% set ns.policy_lookup_calls = desired_policies | length %}
    {% set bulk_sql = dbt_snowflake_rap_enforcement.build_policy_references_by_policies_sql(
      desired_policies,
      target_databases
    ) %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      "Starting apply inventory: strategy=policy; unique_policies="
      ~ (desired_policies | length)
      ~ "; target_databases="
      ~ (target_databases | length)
      ~ "; targets="
      ~ (targets | length)
    ) }}
    {% set bulk_rows = [] %}
    {% if bulk_sql is not none %}
      {% set bulk_result = run_query(bulk_sql) %}
      {% if bulk_result is not none %}
        {% set bulk_rows = bulk_result.rows %}
      {% endif %}
    {% endif %}
    {% set ns.bulk_attachment_rows = bulk_rows | length %}
    {% set partitioned = dbt_snowflake_rap_enforcement.partition_attachment_maps_by_selected_targets(
      dbt_snowflake_rap_enforcement.attachment_maps_from_query_rows(bulk_rows),
      target_key_index
    ) %}
    {% set ns.selected_attachment_hits = partitioned.selected_rows %}
    {% set ns.extra_attachments = partitioned.extra_rows %}
    {% set ns.bulk_maps_by_database = dbt_snowflake_rap_enforcement.group_attachment_maps_by_database(
      partitioned.selected_maps
    ) %}
  {% endif %}

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
    {{ dbt_snowflake_rap_enforcement.package_log(
      "Starting apply inventory: strategy="
      ~ strategy
      ~ "; database="
      ~ database
      ~ "; existing_relation_lookup=1"
    ) }}
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

    {% set db_ns = namespace(
      attachments={},
      relation_targets=[],
      fallback_targets=[],
      lookup_sqls=[],
      lookup_maps=[],
      db_bulk_maps=[]
    ) %}
    {% if strategy == 'relation' %}
      {% set db_ns.relation_targets = dbt_snowflake_rap_enforcement.select_existing_relation_inventory_targets(
        db_targets,
        relations
      ) %}
      {% set ns.relation_lookup_targets = ns.relation_lookup_targets + (db_ns.relation_targets | length) %}
      {% set db_ns.lookup_sqls = dbt_snowflake_rap_enforcement.build_policy_references_sql_batches(
        database,
        db_ns.relation_targets,
        package_vars.policy_references_chunk_size
      ) %}
      {% set ns.relation_lookup_batches = ns.relation_lookup_batches + (db_ns.lookup_sqls | length) %}
      {{ dbt_snowflake_rap_enforcement.package_log(
        "Starting apply inventory: strategy=relation; database="
        ~ database
        ~ "; existing_relations="
        ~ (db_ns.relation_targets | length)
        ~ "; batches="
        ~ (db_ns.lookup_sqls | length)
      ) }}
      {% for relation_sql in db_ns.lookup_sqls %}
        {% set relation_result = run_query(relation_sql) %}
        {% set relation_attach_rows = [] %}
        {% if relation_result is not none %}
          {% set relation_attach_rows = relation_result.rows %}
        {% endif %}
        {% set ns.selected_attachment_hits = ns.selected_attachment_hits + (relation_attach_rows | length) %}
        {% for row_map in dbt_snowflake_rap_enforcement.attachment_maps_from_query_rows(relation_attach_rows) %}
          {% do db_ns.lookup_maps.append(row_map) %}
        {% endfor %}
      {% endfor %}
      {% set db_ns.attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(db_ns.lookup_maps) %}
    {% else %}
      {% if database in ns.bulk_maps_by_database %}
        {% set db_ns.db_bulk_maps = ns.bulk_maps_by_database[database] %}
      {% endif %}
      {% set bulk_attachments = dbt_snowflake_rap_enforcement.index_policy_attachments(db_ns.db_bulk_maps) %}
      {% set db_ns.fallback_targets = dbt_snowflake_rap_enforcement.select_attachment_fallback_targets(
        db_targets,
        relations,
        bulk_attachments
      ) %}
      {% set ns.fallback_relations = ns.fallback_relations + (db_ns.fallback_targets | length) %}
      {% set db_ns.lookup_sqls = dbt_snowflake_rap_enforcement.build_policy_references_sql_batches(
        database,
        db_ns.fallback_targets,
        package_vars.policy_references_chunk_size
      ) %}
      {% set ns.fallback_batches = ns.fallback_batches + (db_ns.lookup_sqls | length) %}
      {% if (db_ns.lookup_sqls | length) > 0 %}
        {{ dbt_snowflake_rap_enforcement.package_log(
          "Starting apply inventory: strategy=policy; database="
          ~ database
          ~ "; fallback_relations="
          ~ (db_ns.fallback_targets | length)
          ~ "; fallback_batches="
          ~ (db_ns.lookup_sqls | length)
        ) }}
      {% endif %}
      {% for fallback_sql in db_ns.lookup_sqls %}
        {% set fallback_result = run_query(fallback_sql) %}
        {% set fallback_rows = [] %}
        {% if fallback_result is not none %}
          {% set fallback_rows = fallback_result.rows %}
        {% endif %}
        {% set ns.selected_attachment_hits = ns.selected_attachment_hits + (fallback_rows | length) %}
        {% for row_map in dbt_snowflake_rap_enforcement.attachment_maps_from_query_rows(fallback_rows) %}
          {% do db_ns.lookup_maps.append(row_map) %}
        {% endfor %}
      {% endfor %}
      {% set db_ns.attachments = dbt_snowflake_rap_enforcement.merge_attachment_indexes(
        bulk_attachments,
        dbt_snowflake_rap_enforcement.index_policy_attachments(db_ns.lookup_maps)
      ) %}
    {% endif %}

    {% set plan = dbt_snowflake_rap_enforcement.plan_row_access_policy_alters(
      db_targets,
      relations,
      db_ns.attachments,
      package_vars.apply_authoritatively
    ) %}
    {% set ns.planned_actions = ns.planned_actions + (plan.actions | length) %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      "apply_row_access_policies inventory for "
      ~ database
      ~ ": strategy="
      ~ strategy
      ~ "; targets="
      ~ (db_targets | length)
      ~ "; relation_lookup_targets="
      ~ (db_ns.relation_targets | length)
      ~ "; relation_lookup_batches="
      ~ (db_ns.lookup_sqls | length if strategy == 'relation' else 0)
      ~ "; fallback_relations="
      ~ (db_ns.fallback_targets | length)
      ~ "; fallback_batches="
      ~ (db_ns.lookup_sqls | length if strategy == 'policy' else 0)
      ~ "; selected_attachment_hits="
      ~ ((db_ns.db_bulk_maps | length) + (db_ns.lookup_maps | length))
      ~ "; planned_actions="
      ~ (plan.actions | length)
      ~ "; missing_relations="
      ~ (plan.skipped_missing | length)
    ) }}

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
        {{ dbt_snowflake_rap_enforcement.package_log(
            "Row access policy apply "
            ~ action.unique_id
            ~ " on "
            ~ action.rel_key
            ~ ": current=none; "
            ~ sql
          ) }}
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
        {% do run_query(drop_sql) %}
        {% do run_query(add_sql) %}
        {% set ns.applied = ns.applied + 2 %}
      {% endif %}
    {% endfor %}
  {% endfor %}

  {{ dbt_snowflake_rap_enforcement.package_log(
    "apply_row_access_policies complete: "
    ~ dbt_snowflake_rap_enforcement.format_apply_inventory_metrics({
      'inventory_strategy': strategy,
      'targets': targets | length,
      'target_databases': target_databases | length,
      'policy_lookup_calls': ns.policy_lookup_calls,
      'bulk_attachment_rows': ns.bulk_attachment_rows,
      'selected_attachment_hits': ns.selected_attachment_hits,
      'extra_attachments': ns.extra_attachments,
      'relation_lookup_targets': ns.relation_lookup_targets,
      'relation_lookup_batches': ns.relation_lookup_batches,
      'fallback_relations': ns.fallback_relations,
      'fallback_batches': ns.fallback_batches,
      'planned_actions': ns.planned_actions,
      'applied': ns.applied,
      'missing_relations': ns.skipped_missing
    })
  ) }}
  {{ return('') }}
{% endmacro %}
