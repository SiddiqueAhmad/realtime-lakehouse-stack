# HIPAA alignment (not a compliance claim)

This repository is **HIPAA-aligned / HIPAA-conscious**: it is built with the
technical controls HIPAA-regulated data flows commonly need — PHI
classification, access control, audit-friendly lineage, data quality gating,
and de-identification paths. It is **not** "HIPAA compliant," and no software
project can claim that on its own.

## Why compliance isn't a code property

HHS's HIPAA Security Rule requires safeguards spanning:

- **Administrative** — risk analysis, workforce training, sanction policies,
  business associate agreements (BAAs).
- **Physical** — facility access controls, device and media controls.
- **Technical** — access control, audit controls, integrity controls,
  transmission security (the category this codebase contributes to).
- **Organizational / contractual** — BAAs with every vendor that touches
  PHI, breach notification procedures, and ongoing risk management.

A repository can implement strong technical controls and still not be part
of a compliant program if the surrounding administrative, physical, and
contractual safeguards aren't in place. So: use the phrase **HIPAA-aligned**
or **HIPAA-conscious** for this project, never **HIPAA compliant**.

## What this repository actually implements

| Control area | Where |
|---|---|
| PHI/sensitivity classification | `governance/phi_classification.yml` |
| Minimum-necessary access (technical) | `infra-setup/trino/rules.json` (file-based access control), role matrix in `governance/phi_classification.yml` |
| Audit-safe lineage (no PHI in metadata) | `warehouse/macros/lineage.sql`, "lineage safety rules" in the PHI registry |
| CDC reliability (integrity of ePHI in transit) | `warehouse/macros/cdc_reliability.sql`, `warehouse/models/bronze/` |
| Data quality / clinical validity gates | `warehouse/models/silver/`, `warehouse/seeds/lab_reference_ranges.csv` |
| De-identification path | `warehouse/models/deid/` (Safe Harbor–style transform; see caveats below) |
| Reliability/quality test scenarios | `reliability-tests/` |

## De-identification caveat

HHS recognizes two methods for HIPAA de-identification:

1. **Safe Harbor** (45 CFR 164.514(b)(2)) — remove a defined list of 18
   identifier types.
2. **Expert Determination** (45 CFR 164.514(b)(1)) — a qualified expert
   applies statistical/scientific methods to conclude re-identification risk
   is very small, and documents that analysis.

`warehouse/models/deid/patients_deidentified.sql` applies Safe-Harbor-*style*
transformations (dropping direct identifiers, generalizing dates/geography)
as a demonstration of the mechanism. It is **not** a substitute for either
formal method: Safe Harbor requires covering the full 18-identifier list and
confirming the covered entity has no actual knowledge the remaining data
could still identify someone; Expert Determination requires a qualified
expert's documented risk assessment. Treat the model here as a starting
point for that review, not a finished compliance artifact.

## Synthetic data only

Every row seeded by this repository (`infra-setup/timescale/healthcare.sql`)
is fictional. No real patient information is stored, transmitted, or
referenced anywhere in this codebase.
