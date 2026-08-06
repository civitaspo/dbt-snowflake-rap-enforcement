{% macro get_package_vars() %}
  {% set cfg = var('dbt_snowflake_rap_enforcement', {}) %}
  {% if cfg is not mapping %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement must be a mapping"
    ) }}
  {% endif %}

  {% set apply_cfg = cfg.get('apply', {}) %}
  {% if apply_cfg is none %}
    {% set apply_cfg = {} %}
  {% endif %}
  {% if apply_cfg is not mapping %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.apply must be a mapping"
    ) }}
  {% endif %}

  {% set require_materializations = cfg.get(
    'require_materializations',
    ['table', 'incremental', 'snapshot', 'dynamic_table']
  ) %}

  {{ return({
    'enforce_downstream': cfg.get('enforce_downstream', false),
    'exclude_resource_types': cfg.get('exclude_resource_types', ['test', 'analysis']),
    'require_materializations': require_materializations,
    'apply': {
      'enabled': apply_cfg.get('enabled', true),
      'dry_run': apply_cfg.get('dry_run', false),
      'selected_only': apply_cfg.get('selected_only', false)
    }
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
      "meta.row_access_policy_enforcement must be a mapping on " ~ node.get('unique_id', node.get('name', 'unknown'))
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
  {# Some graph representations expose config as an object with attribute access. #}
  {% if cfg[key] is defined %}
    {{ return(cfg[key]) }}
  {% endif %}
  {{ return(none) }}
{% endmacro %}

{% macro get_node_materialized(node) %}
  {% set materialized = dbt_snowflake_rap_enforcement.get_node_config_value(node, 'materialized') %}
  {% if materialized is none or materialized | string | length == 0 %}
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

{% macro get_additional_row_access_policies(node) %}
  {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(node) %}
  {% set additional = enforcement.get('additional_row_access_policies', []) %}
  {% if additional is none %}
    {{ return([]) }}
  {% endif %}
  {% if additional is string %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.additional_row_access_policies must be a list on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}
  {% if additional is not iterable or additional is mapping %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.additional_row_access_policies must be a list on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}
  {{ return(additional) }}
{% endmacro %}

{% macro get_desired_policy_entries(node) %}
  {% set primary = dbt_snowflake_rap_enforcement.get_primary_row_access_policy(node) %}
  {% set additional = dbt_snowflake_rap_enforcement.get_additional_row_access_policies(node) %}

  {% if additional | length > 0 and primary is none %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.additional_row_access_policies requires config.row_access_policy on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set entries = [] %}
  {% if primary is not none %}
    {% do entries.append(dbt_snowflake_rap_enforcement.parse_row_access_policy(primary)) %}
  {% endif %}
  {% for item in additional %}
    {% do entries.append(dbt_snowflake_rap_enforcement.parse_row_access_policy(item)) %}
  {% endfor %}
  {{ return(entries) }}
{% endmacro %}

{% macro get_declared_policy_fqns(node) %}
  {% set entries = dbt_snowflake_rap_enforcement.get_desired_policy_entries(node) %}
  {% set fqns = [] %}
  {% for entry in entries %}
    {% do fqns.append(entry.policy_fqn_key) %}
  {% endfor %}
  {{ return(fqns) }}
{% endmacro %}

{% macro node_has_rap_declaration(node) %}
  {{ return(dbt_snowflake_rap_enforcement.get_desired_policy_entries(node) | length > 0) }}
{% endmacro %}

{% macro require_downstream_enabled(node) %}
  {% if not dbt_snowflake_rap_enforcement.node_has_rap_declaration(node) %}
    {{ return(false) }}
  {% endif %}
  {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(node) %}
  {% if enforcement.get('require_downstream') is none %}
    {{ return(true) }}
  {% endif %}
  {% set flag = enforcement.get('require_downstream') %}
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
  {% set allowed = ['inherit', 'any', 'explicit-one-of', 'explicit-all'] %}
  {% if mode_str not in allowed %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.enforce_policy must be one of "
      ~ allowed | join(', ')
      ~ ". Got: " ~ mode
      ~ " on " ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set policies = enforcement.get('policies', []) %}
  {% if policies is none %}
    {% set policies = [] %}
  {% endif %}
  {% if policies is string %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.policies must be a list of policy FQNs on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}
  {% if mode_str in ['explicit-one-of', 'explicit-all'] and policies | length == 0 %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.policies is required when enforce_policy is "
      ~ mode_str
      ~ " on " ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}
  {% if mode_str in ['inherit', 'any'] and policies | length > 0 %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.policies must be empty when enforce_policy is "
      ~ mode_str
      ~ " on " ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {{ return(mode_str) }}
{% endmacro %}

{% macro get_required_policy_fqns(upstream_node) %}
  {% set mode = dbt_snowflake_rap_enforcement.get_enforce_policy_mode(upstream_node) %}
  {% if mode == 'any' %}
    {{ return({'mode': 'any', 'fqns': []}) }}
  {% elif mode == 'inherit' %}
    {{ return({
      'mode': 'all',
      'fqns': dbt_snowflake_rap_enforcement.get_declared_policy_fqns(upstream_node)
    }) }}
  {% elif mode == 'explicit-one-of' %}
    {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream_node) %}
    {% set fqns = [] %}
    {% for item in enforcement.get('policies', []) %}
      {% do fqns.append(item | string | trim | lower) %}
    {% endfor %}
    {{ return({'mode': 'one-of', 'fqns': fqns}) }}
  {% else %}
    {% set enforcement = dbt_snowflake_rap_enforcement.get_enforcement_meta(upstream_node) %}
    {% set fqns = [] %}
    {% for item in enforcement.get('policies', []) %}
      {% do fqns.append(item | string | trim | lower) %}
    {% endfor %}
    {{ return({'mode': 'all', 'fqns': fqns}) }}
  {% endif %}
{% endmacro %}
