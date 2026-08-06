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

  {% set enforce_cfg = cfg.get('enforce', {}) %}
  {% if enforce_cfg is none %}
    {% set enforce_cfg = {} %}
  {% endif %}
  {% if enforce_cfg is not mapping %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.enforce must be a mapping"
    ) }}
  {% endif %}

  {% set require_materializations = cfg.get(
    'require_materializations',
    ['table', 'incremental', 'snapshot', 'dynamic_table']
  ) %}

  {% set apply_commands = apply_cfg.get('commands', ['run', 'build', 'run-operation']) %}
  {% if apply_commands is string or apply_commands is mapping or apply_commands is none %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.apply.commands must be a list"
    ) }}
  {% endif %}
  {% set normalized_commands = [] %}
  {% for command in apply_commands %}
    {% do normalized_commands.append(command | string | trim | lower) %}
  {% endfor %}

  {% set unknown_materialization = enforce_cfg.get('unknown_materialization', 'error') %}
  {% set unknown_materialization_str = unknown_materialization | string | trim | lower %}
  {% if unknown_materialization_str not in ['error', 'skip'] %}
    {{ exceptions.raise_compiler_error(
      "vars.dbt_snowflake_rap_enforcement.enforce.unknown_materialization must be 'error' or 'skip'"
    ) }}
  {% endif %}

  {{ return({
    'enforce_downstream': cfg.get('enforce_downstream', false),
    'exclude_resource_types': cfg.get('exclude_resource_types', ['test', 'analysis']),
    'require_materializations': require_materializations,
    'enforce': {
      'selected_only': enforce_cfg.get('selected_only', false),
      'unknown_materialization': unknown_materialization_str
    },
    'apply': {
      'enabled': apply_cfg.get('enabled', true),
      'dry_run': apply_cfg.get('dry_run', false),
      'selected_only': apply_cfg.get('selected_only', false),
      'commands': normalized_commands
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
      "meta.row_access_policy_enforcement must be a mapping on "
      ~ node.get('unique_id', node.get('name', 'unknown'))
    ) }}
  {% endif %}

  {% set forbidden = [
    'additional_row_access_policies',
    'policies'
  ] %}
  {% for key in forbidden %}
    {% if key in enforcement %}
      {{ exceptions.raise_compiler_error(
        "meta.row_access_policy_enforcement."
        ~ key
        ~ " is not supported (Snowflake allows one RAP per relation). "
        ~ "Use config.row_access_policy for apply/declaration and "
        ~ "enforce_policy/required_policy for downstream lint. Node: "
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

{% macro node_has_rap_declaration(node) %}
  {{ return(dbt_snowflake_rap_enforcement.get_desired_policy_entry(node) is not none) }}
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
    {{ return({'mode': 'any', 'fqn': none, 'display': 'any RAP'}) }}
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
