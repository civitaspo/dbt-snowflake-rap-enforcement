{% macro quote_sf_ident(value) %}
  {{ return('"' ~ (value | string | replace('"', '""')) ~ '"') }}
{% endmacro %}

{% macro relation_ddl_kind(table_type) %}
  {% set t = (table_type | string | upper) %}
  {% if 'DYNAMIC' in t %}
    {{ return('DYNAMIC TABLE') }}
  {% elif t in ['VIEW', 'BASE VIEW'] or 'VIEW' in t %}
    {{ return('VIEW') }}
  {% else %}
    {{ return('TABLE') }}
  {% endif %}
{% endmacro %}

{% macro alter_add_row_access_policy_sql(database, schema, identifier, table_type, policy_fqn, columns_sql) %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type) %}
  {% set fq_name =
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' add row access policy ' ~ policy_fqn
    ~ ' on (' ~ columns_sql ~ ')'
  ) }}
{% endmacro %}

{% macro alter_drop_add_row_access_policy_sql(database, schema, identifier, table_type, old_policy_fqn, policy_fqn, columns_sql) %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type) %}
  {% set fq_name =
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' drop row access policy ' ~ old_policy_fqn
    ~ ', add row access policy ' ~ policy_fqn
    ~ ' on (' ~ columns_sql ~ ')'
  ) }}
{% endmacro %}
