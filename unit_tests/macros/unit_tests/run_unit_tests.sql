{% macro run_unit_tests() %}
  {% do test_parse_row_access_policy() %}
  {% do test_diff_row_access_policies() %}
  {% do test_alter_row_access_policy_sql() %}
  {% do test_build_policy_references_sql() %}
  {% do test_build_existing_relations_sql() %}
  {% do test_node_satisfies_requirement() %}
  {% do test_matches_allow_without_rap() %}

  {{ log("All dbt-snowflake-rap-enforcement unit tests passed.", info=true) }}
{% endmacro %}
