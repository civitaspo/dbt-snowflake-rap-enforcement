{% macro get_package_vars() %}
  {% set cfg = var('dbt_snowflake_rap_enforcement', {}) %}
  {% if cfg is not mapping %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement must be a mapping"
    ) }}
  {% endif %}

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

  {% set chunk_size_raw = cfg.get('policy_references_chunk_size', 75) %}
  {% if chunk_size_raw is none or chunk_size_raw is mapping or chunk_size_raw is iterable and chunk_size_raw is not string %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.policy_references_chunk_size must be a positive integer"
    ) }}
  {% endif %}
  {% set chunk_size = chunk_size_raw | int %}
  {% if chunk_size <= 0 %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.policy_references_chunk_size must be a positive integer"
    ) }}
  {% endif %}

  {{ return({
    'exclude_resource_types': exclude_normalized,
    'passthrough_materializations': passthrough_normalized,
    'apply_authoritatively': apply_authoritatively_bool,
    'policy_references_chunk_size': chunk_size
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

{% macro get_enforce_policy_mode(node) %}
  {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(node) %}
  {% set mode = enforcement.get('enforce_policy', 'inherit') %}
  {% if mode is none or (mode | string | trim | length) == 0 %}
    {% set mode = 'inherit' %}
  {% endif %}
  {% set mode_str = mode | string | trim | lower %}

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
