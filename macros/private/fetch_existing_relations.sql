{% macro build_existing_relations_sql(database, schemas, identifiers=none) %}
  {% if schemas | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set schema_literals = [] %}
  {% for schema_name in schemas %}
    {% do schema_literals.append("'" ~ (schema_name | replace("'", "''") | upper) ~ "'") %}
  {% endfor %}

  {% set identifier_clause = '' %}
  {% if identifiers is not none and identifiers | length > 0 %}
    {% set name_literals = [] %}
    {% for identifier in identifiers %}
      {% do name_literals.append("'" ~ (identifier | replace("'", "''") | upper) ~ "'") %}
    {% endfor %}
    {% set identifier_clause = " and upper(table_name) in (" ~ name_literals | join(', ') ~ ")" %}
  {% endif %}

  {{ return(
    "select "
    ~ "upper(table_catalog) as table_catalog, "
    ~ "upper(table_schema) as table_schema, "
    ~ "upper(table_name) as table_name, "
    ~ "table_type, "
    ~ "is_dynamic "
    ~ "from "
    ~ dbt_snowflake_rap_enforcement.snowflake_information_schema_prefix(database)
    ~ ".information_schema.tables "
    ~ "where upper(table_schema) in ("
    ~ schema_literals | join(', ')
    ~ ")"
    ~ identifier_clause
  ) }}
{% endmacro %}

{% macro index_existing_relations(rows) %}
  {% set index = {} %}
  {% for row in rows %}
    {% set db = row['table_catalog'] | string | upper %}
    {% set schema = row['table_schema'] | string | upper %}
    {% set name = row['table_name'] | string | upper %}
    {% set rel_key = db ~ '.' ~ schema ~ '.' ~ name %}
    {% set is_dynamic = row.get('is_dynamic', 'NO') %}
    {% do index.update({
      rel_key: {
        'database': db,
        'schema': schema,
        'identifier': name,
        'table_type': row['table_type'] | string,
        'is_dynamic': is_dynamic | string
      }
    }) %}
  {% endfor %}
  {{ return(index) }}
{% endmacro %}
