{% macro run_unit_tests() %}
  {% do test_parse_row_access_policy() %}
  {% do test_plan_relation_row_access_policy() %}
  {% do test_plan_row_access_policy_alters() %}
  {% do test_plan_authoritative_replace_alter() %}
  {% do test_alter_row_access_policy_sql() %}
  {% do test_ref_entity_domain_for_materialized() %}
  {% do test_build_policy_references_sql() %}
  {% do test_resolve_apply_target_node_ids() %}
  {% do test_build_existing_relations_sql() %}
  {% do test_index_helpers_and_missing_plan() %}
  {% do test_node_satisfies_requirement() %}
  {% do test_get_downstream_requirement_explicit() %}
  {% do test_matches_allow_without_row_access_policy() %}
  {% do test_collect_downstream_row_access_policy_boundary() %}
  {% do test_global_meta_enforcement_use_cases() %}

  {{ log("All dbt-snowflake-rap-enforcement unit tests passed.", info=true) }}
{% endmacro %}
