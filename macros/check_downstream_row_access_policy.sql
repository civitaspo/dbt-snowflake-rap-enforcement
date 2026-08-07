{#
  Enforce downstream row access policy requirements.

  Wire from the root project:

    on-run-start:
      - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policy() }}"
#}
{% macro check_downstream_row_access_policy() %}
  {{ return(adapter.dispatch('check_downstream_row_access_policy', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__check_downstream_row_access_policy() %}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return('') }}
  {% endif %}

  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}
  {% set selected_only = package_vars.selected_only %}

  {% set nodes_to_check = {} %}
  {% if selected_only %}
    {% if selected_resources is defined and selected_resources is not none %}
      {% for node_id in selected_resources %}
        {% set node = graph.nodes.get(node_id) %}
        {% if node %}
          {% do nodes_to_check.update({node_id: node}) %}
        {% endif %}
      {% endfor %}
    {% endif %}
  {% else %}
    {% set nodes_to_check = graph.nodes %}
  {% endif %}

  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph,
    package_vars,
    nodes_to_check,
    selected_only
  ) %}

  {% if result.violations | length > 0 %}
    {{ log("", info=true) }}
    {{ log("=" * 80, info=true) }}
    {{ log("Downstream row access policy check failed", info=true) }}
    {{ log("=" * 80, info=true) }}
    {{ log("", info=true) }}
    {{ log(
      "Found " ~ result.violations | length ~ " downstream row access policy violation(s):",
      info=true
    ) }}
    {{ log("", info=true) }}

    {% for violation in result.violations %}
      {{ log("Violation " ~ loop.index ~ ":", info=true) }}
      {{ log("  Referencing: " ~ violation.referencing_name ~ " (" ~ violation.referencing_id ~ ")", info=true) }}
      {{ log("  Referenced:  " ~ violation.referenced_name ~ " (" ~ violation.referenced_id ~ ")", info=true) }}
      {{ log("  Reason:      " ~ violation.reason, info=true) }}
      {{ log("  Requirement: " ~ violation.requirement, info=true) }}
      {{ log("", info=true) }}
    {% endfor %}

    {{ log("=" * 80, info=true) }}

    {% if package_vars.fail_on_violation %}
      {{ exceptions.raise_compiler_error(
        "Downstream row access policy check failed with "
        ~ result.violations | length
        ~ " violation(s). Set vars.row_access_policy_enforcement.fail_on_violation "
        ~ "to false to warn only."
      ) }}
    {% else %}
      {{ log(
        "Continuing because vars.row_access_policy_enforcement.fail_on_violation is false",
        info=true
      ) }}
    {% endif %}
  {% else %}
    {{ log(
      "Downstream row access policy check passed ("
      ~ result.checked
      ~ " downstream relationships checked)",
      info=true
    ) }}
  {% endif %}

  {{ return('') }}
{% endmacro %}

{% macro check_downstream_rap() %}
  {{ exceptions.raise_compiler_error(
    "check_downstream_rap() was renamed to check_downstream_row_access_policy()"
  ) }}
{% endmacro %}
