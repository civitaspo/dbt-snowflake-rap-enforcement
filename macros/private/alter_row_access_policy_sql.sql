{% macro quote_sf_ident(value) %}
  {{ return('"' ~ (value | string | replace('"', '""')) ~ '"') }}
{% endmacro %}

{% macro sf_information_schema_prefix(database) %}
  {# Quoted uppercase DB so hyphenated names work; assumes unquoted Snowflake idents. #}
  {{ return(dbt_snowflake_rap_enforcement.quote_sf_ident(database | string | upper)) }}
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
  {% if m in ['view', 'materialized_view'] %}
    {{ return('VIEW') }}
  {% else %}
    {{ return('TABLE') }}
  {% endif %}
{% endmacro %}

{% macro format_policy_fqn_sql(policy_fqn) %}
  {% set fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(policy_fqn) %}
  {% set parts = fqn.split('.') %}
  {{ return(
    dbt_snowflake_rap_enforcement.quote_sf_ident(parts[0] | trim)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(parts[1] | trim)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(parts[2] | trim)
  ) }}
{% endmacro %}

{% macro relation_fq_name_sql(database, schema, identifier) %}
  {{ return(
    dbt_snowflake_rap_enforcement.quote_sf_ident(database)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(schema)
    ~ '.'
    ~ dbt_snowflake_rap_enforcement.quote_sf_ident(identifier)
  ) }}
{% endmacro %}

{% macro alter_add_row_access_policy_sql(database, schema, identifier, table_type, policy_fqn, columns_sql, is_dynamic='NO') %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name = dbt_snowflake_rap_enforcement.relation_fq_name_sql(database, schema, identifier) %}
  {% set safe_fqn = dbt_snowflake_rap_enforcement.format_policy_fqn_sql(policy_fqn) %}
  {% set safe_cols = dbt_snowflake_rap_enforcement.validate_columns_sql(columns_sql) %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' add row access policy ' ~ safe_fqn
    ~ ' on (' ~ safe_cols ~ ')'
  ) }}
{% endmacro %}

{% macro alter_drop_add_row_access_policy_sql(database, schema, identifier, table_type, old_policy_fqn, policy_fqn, columns_sql, is_dynamic='NO') %}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name = dbt_snowflake_rap_enforcement.relation_fq_name_sql(database, schema, identifier) %}
  {% set safe_old = dbt_snowflake_rap_enforcement.format_policy_fqn_sql(old_policy_fqn) %}
  {% set safe_fqn = dbt_snowflake_rap_enforcement.format_policy_fqn_sql(policy_fqn) %}
  {% set safe_cols = dbt_snowflake_rap_enforcement.validate_columns_sql(columns_sql) %}
  {{ return(
    'alter ' ~ kind ~ ' ' ~ fq_name
    ~ ' drop row access policy ' ~ safe_old
    ~ ', add row access policy ' ~ safe_fqn
    ~ ' on (' ~ safe_cols ~ ')'
  ) }}
{% endmacro %}

{% macro alter_drop_all_row_access_policies_sql(database, schema, identifier, table_type, is_dynamic='NO') %}
  {#
    Snowflake documents DROP ALL ROW ACCESS POLICIES as a standalone clause
    (not combinable with ADD). Callers must ADD in a separate statement.
  #}
  {% set kind = dbt_snowflake_rap_enforcement.relation_ddl_kind(table_type, is_dynamic) %}
  {% set fq_name = dbt_snowflake_rap_enforcement.relation_fq_name_sql(database, schema, identifier) %}
  {{ return('alter ' ~ kind ~ ' ' ~ fq_name ~ ' drop all row access policies') }}
{% endmacro %}
