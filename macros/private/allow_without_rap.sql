{#
  allow_without_rap rules mirror dbt-authorized-models match semantics
  (AND within a rule, OR across rules, anchored regex) but live only in this package.
#}
{% macro matches_allow_without_rap(rules, referencing_node) %}
  {% if rules is none %}
    {{ return(false) }}
  {% endif %}
  {% if rules is string %}
    {% if rules == '*' %}
      {{ return(true) }}
    {% endif %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.allow_without_rap must be a list of rules or '*'"
    ) }}
  {% endif %}
  {% if rules is mapping %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.allow_without_rap must be a list of rules"
    ) }}
  {% endif %}
  {% if rules | length == 0 %}
    {{ return(false) }}
  {% endif %}

  {% for rule in rules %}
    {% if dbt_snowflake_rap_enforcement.matches_allow_rule(rule, referencing_node) %}
      {{ return(true) }}
    {% endif %}
  {% endfor %}
  {{ return(false) }}
{% endmacro %}

{% macro matches_allow_rule(rule, node) %}
  {% if rule == '*' %}
    {{ return(true) }}
  {% endif %}
  {% if rule is not mapping %}
    {{ exceptions.raise_compiler_error(
      "allow_without_rap rule must be an object or '*'. Got: " ~ rule
    ) }}
  {% endif %}
  {% if rule | length == 0 %}
    {{ exceptions.raise_compiler_error("allow_without_rap rule objects must contain at least one property") }}
  {% endif %}

  {% for property, pattern in rule.items() %}
    {% if not dbt_snowflake_rap_enforcement.matches_allow_property(property, pattern, node) %}
      {{ return(false) }}
    {% endif %}
  {% endfor %}
  {{ return(true) }}
{% endmacro %}

{% macro matches_allow_property(property, pattern, node) %}
  {% set value = none %}
  {% if property == 'resource_type' %}
    {% set value = node.get('resource_type', '') %}
  {% elif property == 'database' %}
    {% set value = node.get('database', '') %}
  {% elif property == 'schema' %}
    {% set value = node.get('schema', '') %}
  {% elif property == 'identifier' %}
    {% set value = node.get('identifier', '') or node.get('alias', '') or node.get('name', '') %}
  {% elif property == 'alias' %}
    {% set value = node.get('alias', '') or node.get('identifier', '') or node.get('name', '') %}
  {% elif property == 'name' %}
    {% set value = node.get('name', '') %}
  {% elif property == 'package_name' %}
    {% set value = node.get('package_name', '') %}
  {% elif property == 'tags' %}
    {% set node_tags = node.get('tags', []) %}
    {% if node_tags is string %}
      {% set node_tags = [node_tags] %}
    {% endif %}
    {% for tag in node_tags %}
      {% if dbt_snowflake_rap_enforcement.regex_fullmatch(pattern, tag) %}
        {{ return(true) }}
      {% endif %}
    {% endfor %}
    {{ return(false) }}
  {% else %}
    {{ exceptions.raise_compiler_error(
      "Unsupported allow_without_rap property: '" ~ property ~ "'"
    ) }}
  {% endif %}
  {{ return(dbt_snowflake_rap_enforcement.regex_fullmatch(pattern, value)) }}
{% endmacro %}

{% macro regex_fullmatch(pattern, value) %}
  {% set pattern_str = pattern | string %}
  {% set value_str = value | string %}
  {% set core = pattern_str %}
  {% if core.startswith('^') %}
    {% set core = core[1:] %}
  {% endif %}
  {% if core.endswith('$') and (core | length) > 0 %}
    {% set core = core[:-1] %}
  {% endif %}
  {% set anchored = '^(?:' ~ core ~ ')$' %}
  {% set match_result = modules.re.match(anchored, value_str) %}
  {{ return(match_result is not none) }}
{% endmacro %}
