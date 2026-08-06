{% macro diff_desired_vs_attached(desired_entries, attached_for_relation) %}
  {#
    desired_entries: list of parse_row_access_policy results
    attached_for_relation: mapping policy_fqn_key -> {policy_fqn, columns_key}

    Returns:
      add: list of desired entries to ADD
      replace: list of {desired, existing_policy_fqn}
      extras: list of attached policy keys not in desired
  #}
  {% set attached = attached_for_relation if attached_for_relation is not none else {} %}
  {% set desired_keys = [] %}
  {% set add_list = [] %}
  {% set replace_list = [] %}

  {% for desired in desired_entries %}
    {% do desired_keys.append(desired.policy_fqn_key) %}
    {% set existing = attached.get(desired.policy_fqn_key) %}
    {% if existing is none %}
      {% do add_list.append(desired) %}
    {% elif existing.columns_key != desired.columns_key %}
      {% do replace_list.append({
        'desired': desired,
        'existing_policy_fqn': existing.policy_fqn
      }) %}
    {% endif %}
  {% endfor %}

  {% set extras = [] %}
  {% for policy_key, existing in attached.items() %}
    {% if policy_key not in desired_keys %}
      {% do extras.append(existing) %}
    {% endif %}
  {% endfor %}

  {{ return({
    'add': add_list,
    'replace': replace_list,
    'extras': extras
  }) }}
{% endmacro %}
