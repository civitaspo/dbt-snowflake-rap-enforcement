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
    {{ dbt_snowflake_rap_enforcement.package_log('') }}
    {{ dbt_snowflake_rap_enforcement.package_log('=' * 80) }}
    {{ dbt_snowflake_rap_enforcement.package_log(
      'Downstream row access policy check failed'
    ) }}
    {{ dbt_snowflake_rap_enforcement.package_log('=' * 80) }}
    {{ dbt_snowflake_rap_enforcement.package_log('') }}
    {{ dbt_snowflake_rap_enforcement.package_log(
      'Found ' ~ (result.violations | length) ~ ' downstream row access policy violation(s):'
    ) }}
    {{ dbt_snowflake_rap_enforcement.package_log('') }}

    {% for violation in result.violations %}
      {{ dbt_snowflake_rap_enforcement.package_log('Violation ' ~ loop.index ~ ':') }}
      {{ dbt_snowflake_rap_enforcement.package_log(
        '  Referencing: ' ~ violation.referencing_name ~ ' (' ~ violation.referencing_id ~ ')'
      ) }}
      {{ dbt_snowflake_rap_enforcement.package_log(
        '  Referenced:  ' ~ violation.referenced_name ~ ' (' ~ violation.referenced_id ~ ')'
      ) }}
      {{ dbt_snowflake_rap_enforcement.package_log('  Reason:      ' ~ violation.reason) }}
      {{ dbt_snowflake_rap_enforcement.package_log('  Requirement: ' ~ violation.requirement) }}
      {{ dbt_snowflake_rap_enforcement.package_log('') }}
    {% endfor %}

    {{ dbt_snowflake_rap_enforcement.package_log('=' * 80) }}
    {{ exceptions.raise_compiler_error(
      '(dbt-snowflake-rap-enforcement) Downstream row access policy check failed with '
      ~ result.violations | length
      ~ ' violation(s).'
    ) }}
  {% else %}
    {{ dbt_snowflake_rap_enforcement.package_log(
      'Downstream row access policy check passed ('
      ~ result.checked
      ~ ' downstream relationships checked)'
    ) }}
  {% endif %}

  {{ return('') }}
{% endmacro %}
