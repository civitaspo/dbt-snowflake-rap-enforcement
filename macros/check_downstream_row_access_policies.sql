{#
  Enforce downstream row access policy requirements on the full graph.

  Wire from the root project:

    on-run-start:
      - "{{ dbt_snowflake_rap_enforcement.check_downstream_row_access_policies() }}"
#}
{% macro check_downstream_row_access_policies() %}
  {{ return(adapter.dispatch('check_downstream_row_access_policies', 'dbt_snowflake_rap_enforcement')()) }}
{% endmacro %}

{% macro default__check_downstream_row_access_policies() %}
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
  {% set metrics_line = dbt_snowflake_rap_enforcement.format_downstream_check_metrics(result) %}

  {% if result.violations | length > 0 %}
    {{ dbt_snowflake_rap_enforcement.package_log('') }}
    {{ dbt_snowflake_rap_enforcement.package_log('=' * 80) }}
    {{ dbt_snowflake_rap_enforcement.package_log(
      'Downstream row access policy check failed'
    ) }}
    {{ dbt_snowflake_rap_enforcement.package_log('=' * 80) }}
    {{ dbt_snowflake_rap_enforcement.package_log(metrics_line) }}
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
    {{ dbt_snowflake_rap_enforcement.package_log(metrics_line) }}
  {% endif %}

  {{ return('') }}
{% endmacro %}

{% macro format_downstream_check_metrics(result) %}
  {% set stats = {} %}
  {% if result is mapping and result.get('stats') is mapping %}
    {% set stats = result.get('stats') %}
  {% endif %}
  {{ return(
    'Downstream row access policy check metrics: graph_nodes='
    ~ (stats.get('graph_nodes', 0) | string)
    ~ '; rap_sources='
    ~ (stats.get('rap_sources', 0) | string)
    ~ '; dependency_edges='
    ~ (stats.get('dependency_edges', 0) | string)
    ~ '; ancestor_visits='
    ~ (stats.get('ancestor_visits', 0) | string)
    ~ '; child_edges_examined='
    ~ (stats.get('child_edges_examined', 0) | string)
    ~ '; checked='
    ~ (result.get('checked', 0) | string)
  ) }}
{% endmacro %}
