{% macro get_package_vars() %}
  {% if var('row_access_policy_enforcement', none) is not none %}
    {{ exceptions.raise_compiler_error(
      "vars.row_access_policy_enforcement was renamed to vars.dbt_snowflake_rap_enforcement"
    ) }}
  {% endif %}

  {% set cfg = var('dbt_snowflake_rap_enforcement', {}) %}
  {% if cfg is not mapping %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement must be a mapping"
    ) }}
  {% endif %}

  {% set removed_keys = [
    'enforce',
    'apply',
    'apply_enforcement',
    'require_materializations',
    'required_materializations',
    'enforced_materializations',
    'optional_materializations',
    'enforce_downstream',
    'fail_on_violation',
    'selected_only',
    'unknown_materialization',
    'authoritative'
  ] %}
  {% for legacy_key in removed_keys %}
    {% if legacy_key in cfg %}
      {{ exceptions.raise_compiler_error(
        "vars.dbt_snowflake_rap_enforcement."
        ~ legacy_key
        ~ " is not supported. See package README for the current vars schema "
        ~ "(passthrough_materializations, apply_authoritatively, ...)."
      ) }}
    {% endif %}
  {% endfor %}

  {% set passthrough_materializations = cfg.get(
    'passthrough_materializations',
    ['view', 'ephemeral']
  ) %}
  {% if passthrough_materializations is string or passthrough_materializations is mapping or passthrough_materializations is none %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.passthrough_materializations must be a list"
    ) }}
  {% endif %}
  {% set passthrough_normalized = [] %}
  {% for item in passthrough_materializations %}
    {% if item is mapping or item is iterable and item is not string %}
      {{ exceptions.raise_compiler_error(
        "vars.dbt_snowflake_rap_enforcement.passthrough_materializations entries must be strings"
      ) }}
    {% endif %}
    {% do passthrough_normalized.append(item | string | lower | trim) %}
  {% endfor %}

  {% set exclude_resource_types = cfg.get('exclude_resource_types', ['test', 'analysis']) %}
  {% if exclude_resource_types is string or exclude_resource_types is mapping or exclude_resource_types is none %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.exclude_resource_types must be a list"
    ) }}
  {% endif %}
  {% set exclude_normalized = [] %}
  {% for item in exclude_resource_types %}
    {% if item is mapping or item is iterable and item is not string %}
      {{ exceptions.raise_compiler_error(
        "vars.dbt_snowflake_rap_enforcement.exclude_resource_types entries must be strings"
      ) }}
    {% endif %}
    {% do exclude_normalized.append(item | string | lower | trim) %}
  {% endfor %}

  {% set apply_authoritatively = cfg.get('apply_authoritatively', true) %}
  {% if apply_authoritatively is sameas true %}
    {% set apply_authoritatively_bool = true %}
  {% elif apply_authoritatively is sameas false %}
    {% set apply_authoritatively_bool = false %}
  {% elif (apply_authoritatively | string | lower) in ['true', '1', 'yes'] %}
    {% set apply_authoritatively_bool = true %}
  {% elif (apply_authoritatively | string | lower) in ['false', '0', 'no'] %}
    {% set apply_authoritatively_bool = false %}
  {% else %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.apply_authoritatively must be a boolean"
    ) }}
  {% endif %}

  {{ return({
    'exclude_resource_types': exclude_normalized,
    'passthrough_materializations': passthrough_normalized,
    'apply_authoritatively': apply_authoritatively_bool
  }) }}
{% endmacro %}

{% macro get_enforcement_meta(node) %}
  {% set meta = node.get('meta', {}) %}
  {% if meta is none or meta is not mapping %}
    {% set meta = {} %}
  {% endif %}
  {% set enforcement = meta.get('row_access_policy_enforcement', {}) %}
  {% if enforcement is none %}
    {% set enforcement = {} %}
  {% endif %}
  {% if enforcement is not mapping %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement must be a mapping on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set forbidden = {
    'additional_row_access_policies': 'removed (Snowflake allows one RAP per relation)',
    'policies': 'removed; use required_policy with enforce_policy=explicit',
    'allow_without_rap': 'renamed to allow_without_row_access_policy',
    'require_downstream': 'renamed to enforce_downstream'
  } %}
  {% for key, message in forbidden.items() %}
    {% if key in enforcement %}
      {{ exceptions.raise_compiler_error(
        "meta.row_access_policy_enforcement."
        ~ key
        ~ " is not supported ("
        ~ message
        ~ "). Node: "
        ~ node.get('unique_id', node.get('name', 'unknown'))
      ) }}
    {% endif %}
  {% endfor %}

  {{ return(enforcement) }}
{% endmacro %}

{% macro get_node_config_value(node, key) %}
  {% set cfg = node.get('config', {}) %}
  {% if cfg is none %}
    {% set cfg = {} %}
  {% endif %}
  {% if cfg is mapping %}
    {{ return(cfg.get(key)) }}
  {% endif %}
  {% if cfg[key] is defined %}
    {{ return(cfg[key]) }}
  {% endif %}
  {{ return(none) }}
{% endmacro %}

{% macro get_node_materialized(node) %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_config_value(node, 'materialized') %}
  {% if materialized is none or (materialized | string | length) == 0 %}
    {% if node.get('resource_type') == 'snapshot' %}
      {{ return('snapshot') }}
    {% endif %}
    {{ return('view') }}
  {% endif %}
  {{ return(materialized | string) }}
{% endmacro %}

{% macro get_primary_row_access_policy(node) %}
  {% set value = dbt_snowflake_rap_enforcement.get_node_config_value(node, 'row_access_policy') %}
  {% if value is none %}
    {{ return(none) }}
  {% endif %}
  {% set text = value | string | trim %}
  {% if text | length == 0 %}
    {{ return(none) }}
  {% endif %}
  {{ return(text) }}
{% endmacro %}

{% macro get_desired_policy_entry(node) %}
  {% set primary = dbt_snowflake_rap_enforcement.get_primary_row_access_policy(node) %}
  {% if primary is none %}
    {{ return(none) }}
  {% endif %}
  {{ return(dbt_snowflake_rap_enforcement.parse_row_access_policy(primary)) }}
{% endmacro %}

{% macro get_declared_policy_fqn(node) %}
  {% set entry = dbt_snowflake_rap_enforcement.get_desired_policy_entry(node) %}
  {% if entry is none %}
    {{ return(none) }}
  {% endif %}
  {{ return(entry.policy_fqn_key) }}
{% endmacro %}

{% macro node_has_row_access_policy_declaration(node) %}
  {{ return(dbt_snowflake_rap_enforcement.get_desired_policy_entry(node) is not none) }}
{% endmacro %}

{% macro enforce_downstream_enabled(node) %}
  {% if not dbt_snowflake_rap_enforcement.node_has_row_access_policy_declaration(node) %}
    {{ return(false) }}
  {% endif %}
  {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(node) %}
  {% if enforcement.get('enforce_downstream') is none %}
    {{ return(true) }}
  {% endif %}
  {% set flag = enforcement.get('enforce_downstream') %}
  {% if flag is sameas true %}
    {{ return(true) }}
  {% elif flag is sameas false %}
    {{ return(false) }}
  {% elif (flag | string | lower) in ['true', '1', 'yes'] %}
    {{ return(true) }}
  {% else %}
    {{ return(false) }}
  {% endif %}
{% endmacro %}

{% macro get_enforce_policy_mode(node) %}
  {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(node) %}
  {% set mode = enforcement.get('enforce_policy', 'inherit') %}
  {% if mode is none or (mode | string | trim | length) == 0 %}
    {% set mode = 'inherit' %}
  {% endif %}
  {% set mode_str = mode | string | trim | lower %}

  {% if mode_str in ['explicit-one-of', 'explicit-all'] %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.enforce_policy '"
      ~ mode_str
      ~ "' was removed. Use 'explicit' with required_policy. Node: "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set allowed = ['inherit', 'any', 'explicit'] %}
  {% if mode_str not in allowed %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.enforce_policy must be one of "
      ~ allowed | join(', ')
      ~ ". Got: " ~ mode
      ~ " on " ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set required_policy = enforcement.get('required_policy') %}
  {% if mode_str == 'explicit' %}
    {% if required_policy is none or (required_policy | string | trim | length) == 0 %}
      {{ exceptions.raise_compiler_error(
        "meta.row_access_policy_enforcement.required_policy is required when "
        ~ "enforce_policy is 'explicit' on "
        ~ node.get('unique_id', node.get('name', 'unknown'))
      ) }}
    {% endif %}
    {% if required_policy is not string and required_policy is not number %}
      {{ exceptions.raise_compiler_error(
        "meta.row_access_policy_enforcement.required_policy must be a single FQN string on "
        ~ node.get('unique_id', node.get('name', 'unknown'))
      ) }}
    {% endif %}
    {% do dbt_snowflake_rap_enforcement.validate_policy_fqn(required_policy | string | trim) %}
  {% elif required_policy is not none %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.required_policy must be omitted when "
      ~ "enforce_policy is '"
      ~ mode_str
      ~ "' on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {{ return(mode_str) }}
{% endmacro %}

{% macro get_downstream_requirement(upstream_node) %}
  {% set mode = dbt_snowflake_rap_enforcement.get_enforce_policy_mode(upstream_node) %}
  {% if mode == 'any' %}
    {{ return({'mode': 'any', 'fqn': none, 'display': 'any row access policy'}) }}
  {% elif mode == 'inherit' %}
    {% set fqn = dbt_snowflake_rap_enforcement.get_declared_policy_fqn(upstream_node) %}
    {{ return({
      'mode': 'exact',
      'fqn': fqn,
      'display': 'inherit ' ~ fqn
    }) }}
  {% else %}
    {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream_node) %}
    {% set fqn = enforcement.get('required_policy') | string | trim | lower %}
    {{ return({
      'mode': 'exact',
      'fqn': fqn,
      'display': 'explicit ' ~ fqn
    }) }}
  {% endif %}
{% endmacro %}
