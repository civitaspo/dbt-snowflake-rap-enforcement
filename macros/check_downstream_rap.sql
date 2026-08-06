{#
  Enforce RAP-side downstream requirements.

  Wire from the root project:

    on-run-start:
      - "{{ dbt_snowflake_rap_enforcement.check_downstream_rap() }}"
#}
{% macro check_downstream_rap() %}
  {{ return(adapter.dispatch('check_downstream_rap', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__check_downstream_rap() %}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return('') }}
  {% endif %}

  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}

  {% set selected_only = (
    selected_resources is defined
    and selected_resources is not none
    and selected_resources | length > 0
  ) %}
  {% set nodes_to_check = {} %}
  {% if selected_only %}
    {% for node_id in selected_resources %}
      {% set node = graph.nodes.get(node_id) %}
      {% if node %}
        {% do nodes_to_check.update({node_id: node}) %}
      {% endif %}
    {% endfor %}
  {% else %}
    {% set nodes_to_check = graph.nodes %}
  {% endif %}

  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_rap_violations(
    graph,
    package_vars,
    nodes_to_check,
    selected_only
  ) %}

  {% if result.violations | length > 0 %}
    {{ log("", info=true) }}
    {{ log("=" * 80, info=true) }}
    {{ log("Downstream RAP check failed", info=true) }}
    {{ log("=" * 80, info=true) }}
    {{ log("", info=true) }}
    {{ log("Found " ~ result.violations | length ~ " downstream RAP violation(s):", info=true) }}
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

    {% if package_vars.enforce_downstream %}
      {{ exceptions.raise_compiler_error(
        "Downstream RAP check failed with "
        ~ result.violations | length
        ~ " violation(s). Set dbt_snowflake_rap_enforcement.enforce_downstream to false to warn only."
      ) }}
    {% else %}
      {{ log("Continuing because dbt_snowflake_rap_enforcement.enforce_downstream is false", info=true) }}
    {% endif %}
  {% else %}
    {{ log(
      "Downstream RAP check passed (" ~ result.checked ~ " downstream relationships checked)",
      info=true
    ) }}
  {% endif %}

  {{ return('') }}
{% endmacro %}
