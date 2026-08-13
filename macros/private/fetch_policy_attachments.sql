{% macro normalize_ref_arg_column_names(value) %}
  {#
    Convert POLICY_REFERENCES.REF_ARG_COLUMN_NAMES into a comma-separated
    column list for normalize_columns_key.
    Accepts a list/tuple from the adapter, or JSON-ish array text like
    '[ "TENANT_ID" ]' / '["A","B"]'.
  #}
  {% if value is none %}
    {{ return('') }}
  {% endif %}
  {% if value is iterable and value is not string and value is not mapping %}
    {% set parts = [] %}
    {% for item in value %}
      {% do parts.append(item | string | trim) %}
    {% endfor %}
    {{ return(parts | join(',')) }}
  {% endif %}

  {% set raw = value | string | trim %}
  {% if raw | length == 0 or raw | lower in ['none', 'null'] %}
    {{ return('') }}
  {% endif %}

  {% if raw.startswith('[') and raw.endswith(']') %}
    {# Parse JSON-ish array text without modules.json / fromjson (not always available). #}
    {% set inner = raw[1:-1] | trim %}
    {% if inner | length == 0 %}
      {{ return('') }}
    {% endif %}
    {% set parts = [] %}
    {% for part in inner.split(',') %}
      {% set col = part | trim %}
      {% if col.startswith('"') and col.endswith('"') and (col | length) >= 2 %}
        {% set col = col[1:-1] | replace('\\"', '"') %}
      {% elif col.startswith("'") and col.endswith("'") and (col | length) >= 2 %}
        {% set col = col[1:-1] %}
      {% endif %}
      {% if col | length > 0 %}
        {% do parts.append(col) %}
      {% endif %}
    {% endfor %}
    {{ return(parts | join(',')) }}
  {% endif %}

  {{ return(raw) }}
{% endmacro %}

{% macro policy_references_projection_sql() %}
  {{ return(
    "select "
    ~ "upper(ref_database_name) as ref_database, "
    ~ "upper(ref_schema_name) as ref_schema, "
    ~ "upper(ref_entity_name) as ref_entity_name, "
    ~ "lower(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn_key, "
    ~ "coalesce(listagg(ref_column_name, ',') within group (order by ref_column_name), '') as columns_key, "
    ~ "any_value(ref_arg_column_names) as ref_arg_column_names, "
    ~ "any_value(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn "
  ) }}
{% endmacro %}

{% macro chunk_list(items, chunk_size) %}
  {% if items is none or items | length == 0 %}
    {{ return([]) }}
  {% endif %}
  {% set size = chunk_size if chunk_size is not none and chunk_size | int > 0 else 75 %}
  {% set ns = namespace(chunks=[], current=[]) %}
  {% for item in items %}
    {% do ns.current.append(item) %}
    {% if ns.current | length >= size %}
      {% do ns.chunks.append(ns.current) %}
      {% set ns.current = [] %}
    {% endif %}
  {% endfor %}
  {% if ns.current | length > 0 %}
    {% do ns.chunks.append(ns.current) %}
  {% endif %}
  {{ return(ns.chunks) }}
{% endmacro %}

{% macro build_policy_references_sql(database, targets) %}
  {#
    Relation-scoped policy_references so attached FQNs outside the desired
    set remain visible (required for 1-RAP replace / converge).
    targets: list of {schema, identifier, domain}

    RAP attachments on views often leave REF_COLUMN_NAME null and put the
    bound columns in REF_ARG_COLUMN_NAMES instead.
  #}
  {% if targets | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set parts = [] %}
  {% set prefix = dbt_snowflake_rap_enforcement.snowflake_information_schema_prefix(database) %}
  {% set database_name = database | string | upper | replace("'", "''") %}
  {% set projection = dbt_snowflake_rap_enforcement.policy_references_projection_sql() %}
  {% for target in targets %}
    {% set schema_name = target.schema | string | upper | replace("'", "''") %}
    {% set object_name = target.identifier | string | upper | replace("'", "''") %}
    {% set domain = target.domain | string | upper | replace("'", "''") %}
    {% set ref_entity = database_name ~ '.' ~ schema_name ~ '.' ~ object_name %}
    {% do parts.append(
      projection
      ~ " from table("
      ~ prefix
      ~ ".information_schema.policy_references("
      ~ "ref_entity_name => '"
      ~ ref_entity
      ~ "', ref_entity_domain => '"
      ~ domain
      ~ "')) "
      ~ "where policy_kind = 'ROW_ACCESS_POLICY' "
      ~ "group by 1, 2, 3, 4"
    ) %}
  {% endfor %}
  {{ return(parts | join(' union all ')) }}
{% endmacro %}

{% macro build_policy_references_sql_batches(database, targets, chunk_size=75) %}
  {% set batches = [] %}
  {% for chunk in dbt_snowflake_rap_enforcement.chunk_list(targets, chunk_size) %}
    {% set sql = dbt_snowflake_rap_enforcement.build_policy_references_sql(database, chunk) %}
    {% if sql is not none %}
      {% do batches.append(sql) %}
    {% endif %}
  {% endfor %}
  {{ return(batches) }}
{% endmacro %}

{% macro build_policy_references_by_policy_sql(policy_fqn, ref_database=none) %}
  {#
    Policy-centric lookup: one table-function call returns every object
    attached to this RAP. Callers must still relation-scope fallbacks for
    RAP-declared targets missing from this result (unknown stale RAP).
  #}
  {% set fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(policy_fqn) %}
  {% set parts = fqn.split('.') %}
  {% set policy_database = parts[0] | trim %}
  {% set prefix = dbt_snowflake_rap_enforcement.snowflake_information_schema_prefix(policy_database) %}
  {% set policy_name = fqn | string | upper | replace("'", "''") %}
  {% set database_filter = '' %}
  {% if ref_database is not none and (ref_database | string | trim | length) > 0 %}
    {% set database_filter = (
      " and upper(ref_database_name) = '"
      ~ (ref_database | string | upper | replace("'", "''"))
      ~ "'"
    ) %}
  {% endif %}
  {{ return(
    dbt_snowflake_rap_enforcement.policy_references_projection_sql()
    ~ " from table("
    ~ prefix
    ~ ".information_schema.policy_references("
    ~ "policy_name => '"
    ~ policy_name
    ~ "')) "
    ~ "where policy_kind = 'ROW_ACCESS_POLICY'"
    ~ database_filter
    ~ " group by 1, 2, 3, 4"
  ) }}
{% endmacro %}

{% macro build_policy_references_by_policies_sql(policy_fqns, ref_database=none) %}
  {% if policy_fqns is none or policy_fqns | length == 0 %}
    {{ return(none) }}
  {% endif %}
  {% set parts = [] %}
  {% for policy_fqn in policy_fqns %}
    {% do parts.append(
      dbt_snowflake_rap_enforcement.build_policy_references_by_policy_sql(
        policy_fqn,
        ref_database
      )
    ) %}
  {% endfor %}
  {{ return(parts | join(' union all ')) }}
{% endmacro %}

{% macro collect_desired_policy_fqns(targets) %}
  {% set fqns = [] %}
  {% set seen = {} %}
  {% if targets is none %}
    {{ return(fqns) }}
  {% endif %}
  {% for target in targets %}
    {% if target.desired is defined and target.desired is not none %}
      {% set policy_key = target.desired.policy_fqn_key %}
      {% if policy_key not in seen %}
        {% do seen.update({policy_key: true}) %}
        {% do fqns.append(target.desired.policy_fqn) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(fqns) }}
{% endmacro %}

{% macro attachment_lookup_needs_relation_fallback(desired, attached) %}
  {#
    Bulk POLICY_NAME results only see known desired policies.
    Fallback to relation-scoped lookup when a RAP-declared target is absent
    from that index (ADD vs unknown stale RAP).
  #}
  {% if desired is none %}
    {{ return(false) }}
  {% endif %}
  {% if attached is none or attached | length == 0 %}
    {{ return(true) }}
  {% endif %}
  {{ return(false) }}
{% endmacro %}

{% macro select_attachment_fallback_targets(targets, relations, bulk_attachments) %}
  {% set fallback = [] %}
  {% set attachments = bulk_attachments if bulk_attachments is not none else {} %}
  {% for target_node in targets %}
    {% set rel_key = (
      (target_node.database | string | upper)
      ~ '.'
      ~ (target_node.schema | string | upper)
      ~ '.'
      ~ (target_node.identifier | string | upper)
    ) %}
    {% if rel_key in relations %}
      {% if dbt_snowflake_rap_enforcement.attachment_lookup_needs_relation_fallback(
        target_node.desired,
        attachments.get(rel_key, {})
      ) %}
        {% do fallback.append({
          'schema': target_node.schema,
          'identifier': target_node.identifier,
          'domain': target_node.domain
        }) %}
      {% endif %}
    {% endif %}
  {% endfor %}
  {{ return(fallback) }}
{% endmacro %}

{% macro merge_attachment_indexes(base, overlay) %}
  {% set merged = {} %}
  {% if base is not none %}
    {% for rel_key, attached in base.items() %}
      {% do merged.update({rel_key: attached}) %}
    {% endfor %}
  {% endif %}
  {% if overlay is not none %}
    {% for rel_key, attached in overlay.items() %}
      {% do merged.update({rel_key: attached}) %}
    {% endfor %}
  {% endif %}
  {{ return(merged) }}
{% endmacro %}

{% macro attachment_maps_from_query_rows(rows) %}
  {% set attachment_maps = [] %}
  {% if rows is none %}
    {{ return(attachment_maps) }}
  {% endif %}
  {% for row in rows %}
    {% do attachment_maps.append({
      'ref_database': row[0],
      'ref_schema': row[1],
      'ref_entity_name': row[2],
      'policy_fqn_key': row[3],
      'columns_key': row[4],
      'ref_arg_column_names': row[5],
      'policy_fqn': row[6]
    }) %}
  {% endfor %}
  {{ return(attachment_maps) }}
{% endmacro %}

{% macro index_policy_attachments(rows) %}
  {#
    rows: iterable of mappings with ref_database, ref_schema, ref_entity_name,
    policy_fqn_key, columns_key, policy_fqn, and optionally ref_arg_column_names
  #}
  {% set index = {} %}
  {% for row in rows %}
    {% set db = row['ref_database'] | string | upper %}
    {% set schema = row['ref_schema'] | string | upper %}
    {% set name = row['ref_entity_name'] | string | upper %}
    {% set rel_key = db ~ '.' ~ schema ~ '.' ~ name %}
    {% if rel_key not in index %}
      {% do index.update({rel_key: {}}) %}
    {% endif %}
    {% set policy_key = row['policy_fqn_key'] | string | lower %}

    {% set raw_columns_key = '' %}
    {% if row['columns_key'] is defined and row['columns_key'] is not none %}
      {% set raw_columns_key = row['columns_key'] | string | trim %}
    {% endif %}
    {% if raw_columns_key | length == 0 or raw_columns_key | lower == 'none' %}
      {% set arg_names = none %}
      {% if row['ref_arg_column_names'] is defined %}
        {% set arg_names = row['ref_arg_column_names'] %}
      {% endif %}
      {% set raw_columns_key = dbt_snowflake_rap_enforcement.normalize_ref_arg_column_names(arg_names) %}
    {% endif %}
    {% set columns_key = dbt_snowflake_rap_enforcement.normalize_columns_key(raw_columns_key) %}

    {% do index[rel_key].update({
      policy_key: {
        'policy_fqn': row['policy_fqn'] | string,
        'policy_fqn_key': policy_key,
        'columns_key': columns_key
      }
    }) %}
  {% endfor %}
  {{ return(index) }}
{% endmacro %}
