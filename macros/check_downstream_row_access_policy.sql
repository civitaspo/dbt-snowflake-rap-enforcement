{#
  Enforce downstream row access policy requirements on the full graph.

  Wire from the root project:

    on-run-start:
      - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policy() }}"
#}
{% macro check_downstream_row_access_policy() %}
  {{ return(adapter.dispatch('check_downstream_row_access_policy', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__check_downstream_row_access_policy() %}
  {% if not execute %}
    {{ return('') }}
  {% endif %}
  {% if graph is not defined or graph is none or graph.nodes is not defined %}
    {{ return('') }}
  {% endif %}

  {% set package_vars = dbt_snowflake_rap_enforcement.get_package_vars() %}
  {% set result = dbt_snowflake_rap_enforcement.collect_downstream_row_access_policy_violations(
    graph,
    package_vars
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
    {{ exceptions.raise_compiler_error(
      "Downstream row access policy check failed with "
      ~ result.violations | length
      ~ " violation(s)."
    ) }}
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
