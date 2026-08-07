{#
  allow_without_row_access_policy is a list of model/snapshot names (or name
  regex patterns), or the string '*'.

  Matching is against (in order of try):
    - node.name
    - package_name.name
    - unique_id

  Bare names match any package that shares that local name. Prefer
  `package.model` or `unique_id` in multi-package projects.

  An allowed terminal is a trust boundary: the check does not walk past it
  to further downstream models.
#}
{% macro matches_allow_without_row_access_policy(names, referencing_node) %}
  {% if names is none %}
    {{ return(false) }}
  {% endif %}
  {% if names is string %}
    {% if names == '*' %}
      {{ return(true) }}
    {% endif %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.allow_without_row_access_policy must be a list of names or '*'"
    ) }}
  {% endif %}
  {% if names is mapping %}
    {{ exceptions.raise_compiler_error(
      "meta.row_access_policy_enforcement.allow_without_row_access_policy must be a list of names "
      ~ "(not rule objects). Example: ['mart_public_counts']"
    ) }}
  {% endif %}
  {% if names | length == 0 %}
    {{ return(false) }}
  {% endif %}

  {% set node_name = referencing_node.get('name', '') | string %}
  {% set unique_id = referencing_node.get('unique_id', '') | string %}
  {% set package_name = referencing_node.get('package_name', '') | string %}
  {% set candidates = [node_name] %}
  {% if package_name | length > 0 and node_name | length > 0 %}
    {% do candidates.append(package_name ~ '.' ~ node_name) %}
  {% endif %}
  {% if unique_id | length > 0 %}
    {% do candidates.append(unique_id) %}
  {% endif %}

  {% for entry in names %}
    {% if entry == '*' %}
      {{ return(true) }}
    {% endif %}
    {% if entry is mapping or entry is iterable and entry is not string %}
      {{ exceptions.raise_compiler_error(
        "meta.row_access_policy_enforcement.allow_without_row_access_policy entries must be name strings. Got: "
        ~ entry
      ) }}
    {% endif %}
    {% for candidate in candidates %}
      {% if dbt_snowflake_rap_enforcement.regex_fullmatch(entry, candidate) %}
        {{ return(true) }}
      {% endif %}
    {% endfor %}
  {% endfor %}
  {{ return(false) }}
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
