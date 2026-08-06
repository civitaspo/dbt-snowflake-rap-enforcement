{% macro quote_sf_ident(value) %}
  {{ return('"' ~ (value | string | replace('"', '""')) ~ '"') }}
{% endmacro %}

{% macro sf_information_schema_prefix(database) %}
  {# Unquoted uppercase DB name so Information Schema resolves case-insensitively. #}
  {{ return((database | string | upper)) }}
{% endmacro %}

{% macro relation_ddl_kind(table_type, is_dynamic='NO') %}
  {% set dynamic_flag = (is_dynamic | string | upper) %}
  {% if dynamic_flag in ['YES', 'Y', 'TRUE', '1'] %}
    {{ return('DYNAMIC TABLE') }}
  {% endif %}
  {% set t = (table_type | string | upper) %}
  {% if 'DYNAMIC' in t %}
    {{ return('DYNAMIC TABLE') }}
  {% elif t in ['VIEW', 'BASE VIEW'] or 'VIEW' in t %}
    {{ return('VIEW') }}
  {% else %}
    {{ return('TABLE') }}
  {% endif %}
{% endmacro %}

{% macro ref_entity_domain_for_materialized(materialized) %}
  {% set m = materialized | string | lower %}
  {% if m == 'view' %}
    {{ return('VIEW') }}
  {% else %}
    {{ return('TABLE') }}
  {% endif %}
{% endmacro %}

{% macro alter_add_row_access_policy_sql(database, schema, identifier, table_type, policy_fqn, columns_sql, is_dynamic='NO') %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name =
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  %}
  {% set safe_fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(policy_fqn) %}
  {% set safe_cols = dbt_snowflake_rap_enforcement.validate_columns_sql(columns_sql) %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' add row access policy ' ~ safe_fqn
    ~ ' on (' ~ safe_cols ~ ')'
  ) }}
{% endmacro %}

{% macro alter_drop_add_row_access_policy_sql(database, schema, identifier, table_type, old_policy_fqn, policy_fqn, columns_sql, is_dynamic='NO') %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name =
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  %}
  {% set safe_old = dbt_snowflake_rap_enforcement.validate_policy_fqn(old_policy_fqn) %}
  {% set safe_fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(policy_fqn) %}
  {% set safe_cols = dbt_snowflake_rap_enforcement.validate_columns_sql(columns_sql) %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' drop row access policy ' ~ safe_old
    ~ ', add row access policy ' ~ safe_fqn
    ~ ' on (' ~ safe_cols ~ ')'
  ) }}
{% endmacro %}

{% macro alter_drop_all_add_row_access_policy_sql(database, schema, identifier, table_type, policy_fqn, columns_sql, is_dynamic='NO') %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name =
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  %}
  {% set safe_fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(policy_fqn) %}
  {% set safe_cols = dbt_snowflake_rap_enforcement.validate_columns_sql(columns_sql) %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' drop all row access policies'
    ~ ', add row access policy ' ~ safe_fqn
    ~ ' on (' ~ safe_cols ~ ')'
  ) }}
{% endmacro %}
