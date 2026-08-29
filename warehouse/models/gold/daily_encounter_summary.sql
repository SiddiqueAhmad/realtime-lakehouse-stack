{{ config(materialized='table', schema='gold', tags=['gold']) }}

-- Aggregate-only encounter metrics. No PHI-classified column is selected —
-- patient_id is used only inside count(distinct ...) to size the cohort,
-- never emitted as a value — so this table is safe for the broad
-- "analyst" access tier (see governance/phi_classification.yml).

select
    cast(encounter_start as date) as encounter_date,
    encounter_type,
    count(distinct encounter_id) as encounter_count,
    count(distinct patient_id)   as unique_patients
from {{ ref('trusted_encounters') }}
group by cast(encounter_start as date), encounter_type
order by encounter_date, encounter_type
