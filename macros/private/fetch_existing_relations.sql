{% macro build_existing_relations_sql(database, schemas) %}
  {% if schemas | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set schema_literals = [] %}
  {% for schema_name in schemas %}
    {% do schema_literals.append("'" ~ (schema_name | replace("'", "''") | upper) ~ "'") %}
  {% endfor %}

  {{ return(
    "select "
    ~ "upper(table_catalog) as table_catalog, "
    ~ "upper(table_schema) as table_schema, "
    ~ "upper(table_name) as table_name, "
    ~ "table_type "
    ~ "from "
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ ".information_schema.tables "
    ~ "where upper(table_schema) in ("
    ~ schema_literals | join(', ')
    ~ ")"
  ) }}
{% endmacro %}

{% macro index_existing_relations(rows) %}
  {% set index = {} %}
  {% for row in rows %}
    {% set db = row['table_catalog'] | string | upper %}
    {% set schema = row['table_schema'] | string | upper %}
    {% set name = row['table_name'] | string | upper %}
    {% set rel_key = db ~ '.' ~ schema ~ '.' ~ name %}
    {% do index.update({
      rel_key: {
        'database': db,
        'schema': schema,
        'identifier': name,
        'table_type': row['table_type'] | string
      }
    }) %}
  {% endfor %}
  {{ return(index) }}
{% endmacro %}
