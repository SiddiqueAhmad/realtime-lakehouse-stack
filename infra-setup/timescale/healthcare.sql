-- =============================================================================
-- Synthetic healthcare (EHR) operational schema.
--
-- IMPORTANT: This file seeds SYNTHETIC data only. No real patient information
-- is ever committed to this repository. Fields that would carry PHI in a real
-- EHR (name, DOB, contact info, MRN, clinical text, ...) are populated here
-- with clearly fake values so the CDC/reliability/quality/lineage pipeline
-- can be exercised end-to-end against PHI-shaped data.
--
-- See governance/phi_classification.yml for the authoritative column-level
-- PHI classification that the rest of the platform (lineage, access control,
-- de-identification) is built against.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ehr;
SET search_path TO ehr;

-- ---------------------------------------------------------------------------
-- Reference / low-sensitivity entities
-- ---------------------------------------------------------------------------

CREATE TABLE facilities (
    facility_id     SERIAL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    npi             VARCHAR(20),
    facility_type   VARCHAR(50) NOT NULL,
    city            VARCHAR(100),
    state           VARCHAR(2)
);
ALTER TABLE facilities REPLICA IDENTITY FULL;

CREATE TABLE providers (
    provider_id     SERIAL PRIMARY KEY,
    npi             VARCHAR(20) NOT NULL UNIQUE,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    specialty       VARCHAR(100),
    facility_id     INTEGER REFERENCES facilities(facility_id)
);
ALTER TABLE providers REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- Patient — the root of the PHI graph. See governance/phi_classification.yml.
-- ---------------------------------------------------------------------------

CREATE TABLE patients (
    patient_id              SERIAL PRIMARY KEY,
    medical_record_number   VARCHAR(32) NOT NULL UNIQUE, -- PHI
    first_name              VARCHAR(100) NOT NULL,       -- PHI
    last_name               VARCHAR(100) NOT NULL,       -- PHI
    date_of_birth           DATE NOT NULL,                -- PHI
    gender                  VARCHAR(20),
    email                   VARCHAR(255),                 -- PHI
    phone                   VARCHAR(30),                  -- PHI
    address_line1           VARCHAR(255),                 -- PHI
    city                    VARCHAR(100),                 -- PHI (quasi)
    state                   VARCHAR(2),
    postal_code             VARCHAR(10),                  -- PHI (quasi)
    is_deceased             BOOLEAN NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE patients REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- Encounter — a clinical visit; the hub that diagnoses/procedures/labs
-- attach to.
-- ---------------------------------------------------------------------------

CREATE TABLE encounters (
    encounter_id      SERIAL PRIMARY KEY,
    patient_id        INTEGER NOT NULL REFERENCES patients(patient_id),
    provider_id       INTEGER REFERENCES providers(provider_id),
    facility_id       INTEGER REFERENCES facilities(facility_id),
    encounter_type    VARCHAR(50) NOT NULL, -- inpatient / outpatient / emergency / telehealth
    status            VARCHAR(30) NOT NULL DEFAULT 'in-progress',
    encounter_start   TIMESTAMPTZ NOT NULL,
    encounter_end     TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE encounters REPLICA IDENTITY FULL;

CREATE TABLE diagnoses (
    diagnosis_id     SERIAL PRIMARY KEY,
    encounter_id     INTEGER NOT NULL REFERENCES encounters(encounter_id),
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    icd10_code       VARCHAR(10) NOT NULL,
    description      VARCHAR(500) NOT NULL, -- PHI (clinical)
    diagnosed_at     TIMESTAMPTZ NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE diagnoses REPLICA IDENTITY FULL;

CREATE TABLE procedures (
    procedure_id     SERIAL PRIMARY KEY,
    encounter_id     INTEGER NOT NULL REFERENCES encounters(encounter_id),
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    cpt_code         VARCHAR(10) NOT NULL,
    description      VARCHAR(500) NOT NULL, -- PHI (clinical)
    performed_at     TIMESTAMPTZ NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE procedures REPLICA IDENTITY FULL;

CREATE TABLE medications (
    medication_id    SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    encounter_id     INTEGER REFERENCES encounters(encounter_id),
    ndc_code         VARCHAR(20),
    name             VARCHAR(255) NOT NULL, -- PHI (clinical)
    dosage           VARCHAR(100),
    start_date       DATE NOT NULL,
    end_date         DATE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE medications REPLICA IDENTITY FULL;

CREATE TABLE lab_results (
    lab_result_id    SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    encounter_id     INTEGER REFERENCES encounters(encounter_id),
    loinc_code       VARCHAR(20) NOT NULL,
    test_name        VARCHAR(255) NOT NULL, -- PHI (clinical)
    result_value     DOUBLE PRECISION,
    unit             VARCHAR(30),
    abnormal_flag    VARCHAR(10),           -- N / L / H / LL / HH
    result_at        TIMESTAMPTZ NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE lab_results REPLICA IDENTITY FULL;

CREATE TABLE observations (
    observation_id   SERIAL PRIMARY KEY,
    patient_id       INTEGER NOT NULL REFERENCES patients(patient_id),
    encounter_id     INTEGER REFERENCES encounters(encounter_id),
    code             VARCHAR(20) NOT NULL,  -- e.g. LOINC vitals code
    value            VARCHAR(100) NOT NULL, -- PHI (clinical)
    unit             VARCHAR(30),
    observed_at      TIMESTAMPTZ NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE observations REPLICA IDENTITY FULL;

-- ---------------------------------------------------------------------------
-- Synthetic seed data — fictional patients/providers only.
-- ---------------------------------------------------------------------------

INSERT INTO facilities (name, npi, facility_type, city, state) VALUES
    ('Riverbend General Hospital', '1000000001', 'hospital', 'Springfield', 'IL'),
    ('Lakeside Family Clinic', '1000000002', 'clinic', 'Lakeside', 'OR');

INSERT INTO providers (npi, first_name, last_name, specialty, facility_id) VALUES
    ('1200000001', 'Alex', 'Rivera', 'Internal Medicine', 1),
    ('1200000002', 'Jordan', 'Kim', 'Cardiology', 1),
    ('1200000003', 'Sam', 'Osei', 'Family Medicine', 2);

INSERT INTO patients (medical_record_number, first_name, last_name, date_of_birth, gender, email, phone, address_line1, city, state, postal_code) VALUES
    ('MRN-SYN-00001', 'Taylor', 'Example', '1985-04-12', 'female', 'taylor.example@synthetic.test', '555-010-0001', '1 Synthetic Way', 'Springfield', 'IL', '62701'),
    ('MRN-SYN-00002', 'Morgan', 'Sample',  '1972-11-02', 'male',   'morgan.sample@synthetic.test',  '555-010-0002', '2 Synthetic Way', 'Springfield', 'IL', '62701'),
    ('MRN-SYN-00003', 'Casey',  'Fixture', '1998-07-23', 'nonbinary', 'casey.fixture@synthetic.test', '555-010-0003', '3 Synthetic Way', 'Lakeside', 'OR', '97001'),
    ('MRN-SYN-00004', 'Riley',  'Testdata','1950-01-30', 'female', 'riley.testdata@synthetic.test', '555-010-0004', '4 Synthetic Way', 'Lakeside', 'OR', '97001');

INSERT INTO encounters (patient_id, provider_id, facility_id, encounter_type, status, encounter_start, encounter_end) VALUES
    (1, 1, 1, 'outpatient', 'finished', '2026-01-05 09:00:00+00', '2026-01-05 09:30:00+00'),
    (2, 2, 1, 'inpatient',  'finished', '2026-01-06 08:00:00+00', '2026-01-09 14:00:00+00'),
    (3, 3, 2, 'outpatient', 'finished', '2026-02-01 10:15:00+00', '2026-02-01 10:45:00+00'),
    (4, 1, 1, 'emergency',  'finished', '2026-02-10 22:00:00+00', '2026-02-11 02:00:00+00');

INSERT INTO diagnoses (encounter_id, patient_id, icd10_code, description, diagnosed_at) VALUES
    (1, 1, 'E11.9', 'Type 2 diabetes mellitus without complications', '2026-01-05 09:20:00+00'),
    (2, 2, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-01-06 08:30:00+00'),
    (3, 3, 'J06.9', 'Acute upper respiratory infection, unspecified', '2026-02-01 10:30:00+00'),
    (4, 4, 'S72.001A', 'Fracture of neck of right femur, initial encounter', '2026-02-10 22:30:00+00');

INSERT INTO procedures (encounter_id, patient_id, cpt_code, description, performed_at) VALUES
    (2, 2, '92941', 'Percutaneous coronary intervention', '2026-01-06 10:00:00+00'),
    (4, 4, '27245', 'Treatment of intertrochanteric fracture', '2026-02-11 01:00:00+00');

INSERT INTO medications (patient_id, encounter_id, ndc_code, name, dosage, start_date, end_date) VALUES
    (1, 1, '00069-0420-30', 'Metformin', '500mg twice daily', '2026-01-05', NULL),
    (2, 2, '00071-0155-23', 'Atorvastatin', '80mg once daily', '2026-01-06', NULL),
    (3, 3, '00093-7146-01', 'Amoxicillin', '500mg three times daily', '2026-02-01', '2026-02-08');

INSERT INTO lab_results (patient_id, encounter_id, loinc_code, test_name, result_value, unit, abnormal_flag, result_at) VALUES
    (1, 1, '4548-4',  'Hemoglobin A1c', 7.8,  '%',     'H', '2026-01-05 09:15:00+00'),
    (2, 2, '2160-0',  'Creatinine',     1.1,  'mg/dL', 'N', '2026-01-06 08:45:00+00'),
    (2, 2, '2823-3',  'Potassium',      4.2,  'mmol/L','N', '2026-01-06 08:45:00+00'),
    (3, 3, '2160-0',  'Creatinine',     0.9,  'mg/dL', 'N', '2026-02-01 10:20:00+00');

INSERT INTO observations (patient_id, encounter_id, code, value, unit, observed_at) VALUES
    (1, 1, '8480-6', '128', 'mmHg', '2026-01-05 09:05:00+00'),
    (2, 2, '8867-4', '92',  'bpm',  '2026-01-06 08:05:00+00'),
    (4, 4, '8310-5', '38.6','Cel',  '2026-02-10 22:05:00+00');
