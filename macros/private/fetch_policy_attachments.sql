{% macro build_policy_references_sql(database, targets) %}
  {#
    Relation-scoped policy_references so attached FQNs outside the desired
    set remain visible (required for 1-RAP replace / converge).
    targets: list of {schema, identifier, domain}
  #}
  {% if targets | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set parts = [] %}
  {% set prefix = dbt_snowflake_rap_enforcement.sf_information_schema_prefix(database) %}
  {% set database_name = database | string | upper | replace("'", "''") %}
  {% for target in targets %}
    {% set schema_name = target.schema | string | upper | replace("'", "''") %}
    {% set object_name = target.identifier | string | upper | replace("'", "''") %}
    {% set domain = target.domain | string | upper | replace("'", "''") %}
    {% set ref_entity = database_name ~ '.' ~ schema_name ~ '.' ~ object_name %}
    {% do parts.append(
      "select "
      ~ "upper(ref_database_name) as ref_database, "
      ~ "upper(ref_schema_name) as ref_schema, "
      ~ "upper(ref_entity_name) as ref_entity_name, "
      ~ "lower(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn_key, "
      ~ "listagg(ref_column_name, ',') within group (order by ref_column_name) as columns_key, "
      ~ "any_value(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn "
      ~ "from table("
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

{% macro index_policy_attachments(rows) %}
  {#
    rows: iterable of mappings with ref_database, ref_schema, ref_entity_name,
    policy_fqn_key, columns_key, policy_fqn
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
    {% set columns_key = dbt_snowflake_rap_enforcement.normalize_columns_key(row['columns_key']) %}
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
