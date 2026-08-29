{{ config(materialized='view', schema='deid', tags=['deid']) }}

-- Safe-Harbor-STYLE de-identification demonstration. This drops or
-- generalizes every column governance/phi_classification.yml marks PHI or
-- QUASI_PHI for ehr.patients. It illustrates the mechanism only — it is
-- NOT a substitute for a full Safe Harbor determination (all 18 identifier
-- categories, "no actual knowledge" review) or an Expert Determination.
-- See docs/hipaa_alignment.md.
--
-- Reads from trusted_patients (post data-quality-gate), not bronze/silver
-- directly, so de-identified analytics never inherits an unvalidated row.

select
    record_token,                                     -- non-reversible stand-in for patient_id
    gender,
    date_part('year', date_of_birth) as birth_year,    -- date generalized to year only
    case
        when date_diff('year', date_of_birth, current_date) >= 90 then '90+'
        else cast((date_diff('year', date_of_birth, current_date) / 10) * 10 as varchar) || 's'
    end as age_band,
    state,
    -- Safe Harbor permits a 3-digit ZIP only when the corresponding
    -- population exceeds 20,000; that population check isn't implemented
    -- here (no census reference data), so treat this column as illustrative,
    -- not a compliant geographic generalization.
    substr(postal_code, 1, 3) as postal_code_3digit,
    is_deceased,
    quality_status
from {{ ref('trusted_patients') }}
