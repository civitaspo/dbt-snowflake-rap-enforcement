{#
  Parse a Snowflake RAP config string: "db.schema.policy on (col1, col2)".

  Returns a mapping:
    - raw
    - policy_fqn
    - columns_sql   (contents inside parentheses, trimmed)
    - columns_key   (normalized lower-case columns for comparison)
#}
{% macro parse_row_access_policy(policy_string) %}
  {% if policy_string is none %}
    {{ return(none) }}
  {% endif %}

  {% set raw = policy_string | string | trim %}
  {% if raw | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {% set match = modules.re.search(
    '(?is)^(.+?)\\s+on\\s*\\((.+)\\)\\s*$',
    raw
  ) %}
  {% if match is none %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy string (expected 'fqn on (columns)'): " ~ raw
    ) }}
  {% endif %}

  {% set policy_fqn = match.group(1) | trim %}
  {% set columns_sql = match.group(2) | trim %}
  {% set columns_key = modules.re.sub('\\s+', '', columns_sql) | lower %}

  {% if policy_fqn | length == 0 or columns_sql | length == 0 %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy string (empty policy or columns): " ~ raw
    ) }}
  {% endif %}

  {{ return({
    'raw': raw,
    'policy_fqn': policy_fqn,
    'policy_fqn_key': policy_fqn | lower,
    'columns_sql': columns_sql,
    'columns_key': columns_key
  }) }}
{% endmacro %}

{% macro policy_fqn_from_string(policy_string) %}
  {% set parsed = dbt_snowflake_rap_enforcement.parse_row_access_policy(policy_string) %}
  {% if parsed is none %}
    {{ return(none) }}
  {% endif %}
  {{ return(parsed.policy_fqn) }}
{% endmacro %}
