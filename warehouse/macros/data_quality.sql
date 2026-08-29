{#
  Data quality gate helpers.

  A model calls these with a `checks` dict of {failure_reason: passing_condition_sql}.
  A row's quality_status is 'PASS' only if every condition evaluates true;
  failed_checks lists which named reasons it failed, so a quarantined row is
  actionable rather than just "rejected".

  Categories these checks are meant to express (per governance/phi_classification.yml
  and the reliability test suite in reliability-tests/):
    - completeness         (a required field is null)
    - validity             (a field's value is out of a valid shape/format/range)
    - referential integrity (a foreign key doesn't resolve to a live parent row)
    - clinical plausibility (a clinical value is outside physiologically
                              plausible bounds — see seeds/lab_reference_ranges.csv)
#}

{% macro dq_quality_status(checks) %}
    case when {{ checks.values() | join('
        and ') }}
    then 'PASS' else 'FAIL' end
{% endmacro %}

{% macro dq_failed_checks(checks) %}
    array_join(
        filter(
            array[
                {% for name, expr in checks.items() %}
                case when not ({{ expr }}) then '{{ name }}' end{{ "," if not loop.last }}
                {% endfor %}
            ],
            x -> x is not null
        ),
        ','
    )
{% endmacro %}
