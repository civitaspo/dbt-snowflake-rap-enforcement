{#
  Parse a Snowflake RAP config string: "db.schema.policy on (col1, col2)".

  Snowflake allows one RAP per relation. This parser accepts a single
  "fqn on (columns)" string and normalizes columns for set comparison.

  Returns:
    - raw
    - policy_fqn
    - policy_fqn_key (lower)
    - columns_sql (validated, original order for DDL)
    - columns_key (sorted, unquoted, lower)
#}
{% macro normalize_columns_key(columns_sql) %}
  {% set parts = (columns_sql | string).split(',') %}
  {% set normalized = [] %}
  {% for part in parts %}
    {% set col = part | trim %}
    {% if col | length == 0 %}
      {{ exceptions.raise_compiler_error(
        "Invalid row_access_policy columns (empty column name): " ~ columns_sql
      ) }}
    {% endif %}
    {% if col.startswith('"') and col.endswith('"') and (col | length) >= 2 %}
      {% set col = col[1:-1] | replace('""', '"') %}
    {% endif %}
    {% do normalized.append(col | lower) %}
  {% endfor %}
  {{ return(normalized | sort | join(',')) }}
{% endmacro %}

{% macro is_snowflake_ident(value) %}
  {% set text = value | string | trim %}
  {% if text | length == 0 %}
    {{ return(false) }}
  {% endif %}
  {% if text.startswith('"') and text.endswith('"') and (text | length) >= 2 %}
    {# Quoted identifier: non-empty interior, no unescaped control quotes issues. #}
    {{ return(true) }}
  {% endif %}
  {{ return(modules.re.match('^[A-Za-z_][A-Za-z0-9_$]*$', text) is not none) }}
{% endmacro %}

{% macro validate_policy_fqn(policy_fqn) %}
  {% set fqn = policy_fqn | string | trim %}
  {% if modules.re.search('[;]|--|/\\*|\\*/|,', fqn) %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy FQN (forbidden characters): " ~ fqn
    ) }}
  {% endif %}
  {% set parts = fqn.split('.') %}
  {% if parts | length != 3 %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy FQN (expected db.schema.name): " ~ fqn
    ) }}
  {% endif %}
  {% for part in parts %}
    {% set component = part | trim %}
    {% if not dbt_snowflake_rap_enforcement.is_snowflake_ident(component) %}
      {{ exceptions.raise_compiler_error(
        "Invalid row_access_policy FQN component (expected Snowflake identifier): "
        ~ component
        ~ " in "
        ~ fqn
      ) }}
    {% endif %}
  {% endfor %}
  {{ return(fqn) }}
{% endmacro %}

{% macro validate_columns_sql(columns_sql) %}
  {% set cols = columns_sql | string | trim %}
  {% if cols | length == 0 %}
    {{ exceptions.raise_compiler_error("Invalid row_access_policy columns (empty)") }}
  {% endif %}
  {% if modules.re.search('[;]|--|/\\*|\\*/|[()]', cols) %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy columns (forbidden characters): " ~ cols
    ) }}
  {% endif %}
  {% set parts = cols.split(',') %}
  {% for part in parts %}
    {% set col = part | trim %}
    {% if not dbt_snowflake_rap_enforcement.is_snowflake_ident(col) %}
      {{ exceptions.raise_compiler_error(
        "Invalid row_access_policy column (expected Snowflake identifier): " ~ col
      ) }}
    {% endif %}
  {% endfor %}
  {{ return(cols) }}
{% endmacro %}

{% macro parse_row_access_policy(policy_string) %}
  {% if policy_string is none %}
    {{ return(none) }}
  {% endif %}

  {% set raw = policy_string | string | trim %}
  {% if raw | length == 0 %}
    {{ return(none) }}
  {% endif %}

  {# Greedy FQN + columns without nested parentheses (rightmost on-clause). #}
  {% set match = modules.re.search(
    '(?is)^(.+)\\s+on\\s*\\(([^()]*)\\)\\s*$',
    raw
  ) %}
  {% if match is none %}
    {{ exceptions.raise_compiler_error(
      "Invalid row_access_policy string (expected 'fqn on (columns)'): " ~ raw
    ) }}
  {% endif %}

  {% set policy_fqn = dbt_snowflake_rap_enforcement.validate_policy_fqn(match.group(1) | trim) %}
  {% set columns_sql = dbt_snowflake_rap_enforcement.validate_columns_sql(match.group(2) | trim) %}
  {% set columns_key = dbt_snowflake_rap_enforcement.normalize_columns_key(columns_sql) %}

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
