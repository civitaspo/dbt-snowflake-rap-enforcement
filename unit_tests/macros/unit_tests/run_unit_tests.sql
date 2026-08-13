{% macro run_unit_tests() %}
  {% do test_parse_row_access_policy() %}
  {% do test_plan_relation_row_access_policy() %}
  {% do test_plan_row_access_policy_alters() %}
  {% do test_plan_authoritative_replace_alter() %}
  {% do test_plan_drop_when_config_cleared() %}
  {% do test_alter_row_access_policy_sql() %}
  {% do test_format_policy_fqn_sql_uppercases_unquoted() %}
  {% do test_ref_entity_domain_for_materialized() %}
  {% do test_build_policy_references_sql() %}
  {% do test_build_policy_references_by_policy_sql() %}
  {% do test_chunk_list_and_policy_reference_batches() %}
  {% do test_normalize_ref_arg_column_names() %}
  {% do test_resolve_apply_target_node_ids() %}
  {% do test_build_existing_relations_sql() %}
  {% do test_index_helpers_and_missing_plan() %}
  {% do test_plan_noop_when_columns_from_ref_arg_column_names() %}
  {% do test_hybrid_policy_inventory_selection() %}
  {% do test_node_satisfies_requirement() %}
  {% do test_get_downstream_requirement_explicit() %}
  {% do test_matches_allow_without_row_access_policy() %}
  {% do test_collect_downstream_row_access_policy_boundary() %}
  {% do test_global_meta_enforcement_use_cases() %}

  {{ log("All dbt-snowflake-rap-enforcement unit tests passed.", info=true) }}
{% endmacro %}
