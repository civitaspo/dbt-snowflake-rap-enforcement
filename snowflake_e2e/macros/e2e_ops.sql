{% macro e2e_create_policy(policy_fqn) %}
  {#
    Create a permissive RAP used only by local Snowflake E2E runs.
    policy_fqn: db.schema.name (three unquoted identifier parts)
  #}
  {% set parts = (policy_fqn | string).split('.') %}
  {% if parts | length != 3 %}
    {{ exceptions.raise_compiler_error("e2e_create_policy expects db.schema.name, got: " ~ policy_fqn) }}
  {% endif %}
  {% set db = dbt_snowflake_rap_enforcement.quote_sf_ident(parts[0]) %}
  {% set sch = dbt_snowflake_rap_enforcement.quote_sf_ident(parts[1]) %}
  {% set name = dbt_snowflake_rap_enforcement.quote_sf_ident(parts[2]) %}
  {% set sql %}
    create row access policy if not exists {{ db }}.{{ sch }}.{{ name }}
    as (tenant_id number) returns boolean -> true
  {% endset %}
  {% do run_query(sql) %}
  {{ log("Created row access policy " ~ policy_fqn, info=true) }}
  {{ return('') }}
{% endmacro %}

{% macro e2e_create_bare_table(database, schema, identifier) %}
  {# Existing relation with no RAP — the package must ADD on apply. #}
  {% set db = dbt_snowflake_rap_enforcement.quote_sf_ident(database | upper) %}
  {% set sch = dbt_snowflake_rap_enforcement.quote_sf_ident(schema | upper) %}
  {% set ident = dbt_snowflake_rap_enforcement.quote_sf_ident(identifier | upper) %}
  {% set fq = db ~ '.' ~ sch ~ '.' ~ ident %}
  {% do run_query('create or replace table ' ~ fq ~ ' as select 1::number as tenant_id, \'bare\' as payload') %}
  {{ log(
    "Created bare table (no RAP) "
    ~ (database | upper) ~ '.' ~ (schema | upper) ~ '.' ~ (identifier | upper),
    info=true
  ) }}
  {{ return('') }}
{% endmacro %}

{% macro e2e_list_attached_policies(database, schema, identifier) %}
  {% set db = database | string | upper %}
  {% set sch = schema | string | upper %}
  {% set ident = identifier | string | upper %}
  {% set prefix = dbt_snowflake_rap_enforcement.sf_information_schema_prefix(db) %}
  {% set ref_entity = (db ~ '.' ~ sch ~ '.' ~ ident) | replace("'", "''") %}
  {% set sql %}
    select lower(policy_db || '.' || policy_schema || '.' || policy_name) as policy_fqn_key
    from table(
      {{ prefix }}.information_schema.policy_references(
        ref_entity_name => '{{ ref_entity }}',
        ref_entity_domain => 'TABLE'
      )
    )
    where policy_kind = 'ROW_ACCESS_POLICY'
  {% endset %}
  {% set result = run_query(sql) %}
  {% set found = [] %}
  {% if result is not none %}
    {% for row in result.rows %}
      {% do found.append(row[0] | string | lower) %}
    {% endfor %}
  {% endif %}
  {{ return(found) }}
{% endmacro %}

{% macro e2e_assert_policy_absent(database, schema, identifier) %}
  {% set found = e2e_list_attached_policies(database, schema, identifier) %}
  {% if found | length > 0 %}
    {{ exceptions.raise_compiler_error(
      "E2E assert failed: expected no RAP on "
      ~ (database | upper) ~ '.' ~ (schema | upper) ~ '.' ~ (identifier | upper)
      ~ ", found "
      ~ found
    ) }}
  {% endif %}
  {{ log(
    "E2E assert passed: no RAP on "
    ~ (database | upper) ~ '.' ~ (schema | upper) ~ '.' ~ (identifier | upper),
    info=true
  ) }}
  {{ return('') }}
{% endmacro %}

{% macro e2e_assert_policy_attached(database, schema, identifier, policy_fqn) %}
  {% set expected = policy_fqn | string | lower %}
  {% set found = e2e_list_attached_policies(database, schema, identifier) %}
  {% set ref_entity = (database | upper) ~ '.' ~ (schema | upper) ~ '.' ~ (identifier | upper) %}
  {% if found | length == 0 %}
    {{ exceptions.raise_compiler_error(
      "E2E assert failed: no row access policy attached to "
      ~ ref_entity
      ~ " (expected "
      ~ expected
      ~ ")"
    ) }}
  {% endif %}
  {% if expected not in found %}
    {{ exceptions.raise_compiler_error(
      "E2E assert failed: expected policy "
      ~ expected
      ~ " on "
      ~ ref_entity
      ~ ", found "
      ~ found
    ) }}
  {% endif %}
  {% if found | length != 1 %}
    {{ exceptions.raise_compiler_error(
      "E2E assert failed: expected exactly one RAP on "
      ~ ref_entity
      ~ ", found "
      ~ found
    ) }}
  {% endif %}
  {{ log("E2E assert passed: " ~ ref_entity ~ " -> " ~ expected, info=true) }}
  {{ return('') }}
{% endmacro %}

{% macro e2e_drop_schema(database, schema) %}
  {% set db = dbt_snowflake_rap_enforcement.quote_sf_ident(database) %}
  {% set sch = dbt_snowflake_rap_enforcement.quote_sf_ident(schema) %}
  {% do run_query('drop schema if exists ' ~ db ~ '.' ~ sch ~ ' cascade') %}
  {{ log("Dropped schema " ~ database ~ '.' ~ schema, info=true) }}
  {{ return('') }}
{% endmacro %}

{% macro e2e_create_schema(database, schema) %}
  {% set db = dbt_snowflake_rap_enforcement.quote_sf_ident(database) %}
  {% set sch = dbt_snowflake_rap_enforcement.quote_sf_ident(schema) %}
  {% do run_query('create schema if not exists ' ~ db ~ '.' ~ sch) %}
  {{ log("Ensured schema " ~ database ~ '.' ~ schema, info=true) }}
  {{ return('') }}
{% endmacro %}
