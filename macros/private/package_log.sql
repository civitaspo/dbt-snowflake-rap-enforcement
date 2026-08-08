{#
  Info/debug logs from this package. Use parentheses so the prefix is not
  confused with dbt's bracketed log level (e.g. [info ]).
#}
{% macro package_log(message, info=true) %}
  {% set text = message if message is not none else '' %}
  {% if text | string | length == 0 %}
    {{ log('', info=info) }}
  {% else %}
    {{ log('(dbt-snowflake-rap-enforcement) ' ~ text, info=info) }}
  {% endif %}
{% endmacro %}
