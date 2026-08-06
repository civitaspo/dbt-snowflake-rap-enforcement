{% macro build_policy_references_sql(database, policy_fqns) %}
  {% if policy_fqns | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set parts = [] %}
  {% for policy_fqn in policy_fqns %}
    {% set escaped = policy_fqn | replace("'", "''") %}
    {% do parts.append(
      "select "
      ~ "upper(ref_database) as ref_database, "
      ~ "upper(ref_schema) as ref_schema, "
      ~ "upper(ref_entity_name) as ref_entity_name, "
      ~ "upper(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn_key, "
      ~ "listagg(ref_column_name, ',') within group (order by ref_column_name) as columns_key, "
      ~ "any_value(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn "
      ~ "from table("
      ~ dbt_snowflake_rap_enforcement.quote_sf_ident(database)
      ~ ".information_schema.policy_references(policy_name => '"
      ~ escaped
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
    {% set columns_key = modules.re.sub('\\s+', '', row['columns_key'] | string) | lower %}
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
