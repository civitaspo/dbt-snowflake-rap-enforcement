{% macro plan_relation_rap(desired, attached_for_relation) %}
  {#
    desired: single parse_row_access_policy result (required)
    attached_for_relation: mapping policy_fqn_key -> {policy_fqn, columns_key}

    Returns action: noop | add | replace | replace_all
  #}
  {% set attached = attached_for_relation if attached_for_relation is not none else {} %}
  {% set attached_entries = [] %}
  {% for _policy_key, existing in attached.items() %}
    {% do attached_entries.append(existing) %}
  {% endfor %}

  {% if attached_entries | length == 0 %}
    {{ return({'action': 'add', 'desired': desired}) }}
  {% endif %}

  {% if attached_entries | length == 1 %}
    {% set existing = attached_entries[0] %}
    {% if existing.policy_fqn_key == desired.policy_fqn_key and existing.columns_key == desired.columns_key %}
      {{ return({'action': 'noop', 'desired': desired}) }}
    {% endif %}
    {{ return({
      'action': 'replace',
      'desired': desired,
      'existing_policy_fqn': existing.policy_fqn
    }) }}
  {% endif %}

  {{ return({'action': 'replace_all', 'desired': desired}) }}
{% endmacro %}

{% macro plan_rap_alters(targets, relations_index, attachments_index) %}
  {#
    Pure planner for unit tests.
    Returns:
      actions: list of {action, rel_key, unique_id, desired, existing?, relation?}
      skipped_missing: list of {rel_key, unique_id, name}
  #}
  {% set actions = [] %}
  {% set skipped_missing = [] %}

  {% for target_node in targets %}
    {% set rel_key = (
      (target_node.database | string | upper)
      ~ '.'
      ~ (target_node.schema | string | upper)
      ~ '.'
      ~ (target_node.identifier | string | upper)
    ) %}
    {% set existing = relations_index.get(rel_key) %}
    {% if existing is none %}
      {% do skipped_missing.append({
        'rel_key': rel_key,
        'unique_id': target_node.unique_id,
        'name': target_node.name
      }) %}
    {% else %}
      {% set attached = attachments_index.get(rel_key, {}) %}
      {% set plan = dbt_snowflake_rap_enforcement.plan_relation_rap(
        target_node.desired,
        attached
      ) %}
      {% if plan.action != 'noop' %}
        {% do actions.append({
          'action': plan.action,
          'rel_key': rel_key,
          'unique_id': target_node.unique_id,
          'desired': plan.desired,
          'existing_policy_fqn': plan.get('existing_policy_fqn'),
          'relation': existing
        }) %}
      {% endif %}
    {% endif %}
  {% endfor %}

  {{ return({
    'actions': actions,
    'skipped_missing': skipped_missing
  }) }}
{% endmacro %}
