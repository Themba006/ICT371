-- ============================================================
-- ICT371 Advanced Database - Question 4: Clinic Appointment Scheduling
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- ============================================================

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path TO q4_clinic, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_slot   CHECK (slot_time IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time)),
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
    ('Brian Phiri'), ('Chanda Mwansa'), ('Thandiwe Banda');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Mulenga'), ('Dr. Zulu'), ('Dr. Tembo');

-- ------------------------------------------------------------
-- (d) Trigger: reject a clash with another non-cancelled appointment
-- (installed before the appointments are seeded)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_exclude_id INTEGER;
BEGIN
    -- A cancelled appointment never occupies a slot
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    -- On UPDATE, ignore the appointment being changed itself
    IF TG_OP = 'UPDATE' THEN
        v_exclude_id := OLD.appointment_id;
    ELSE
        v_exclude_id := -1;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          AND a.appointment_id <> v_exclude_id
    ) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_before_write
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appointments_no_clash();

-- Six appointments, none breaking the slot rule.
-- #6 is CANCELLED and shares doctor/date/slot with #1, which is allowed.
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE + 1, '12:00', 'BOOKED'),
    (3, 1, CURRENT_DATE,     '09:00', 'CANCELLED');

SELECT * FROM appointments ORDER BY appointment_id;

-- ------------------------------------------------------------
-- (b) Function: fn_daily_load
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;   -- COUNT(*) is 0 when there are no bookings
END;
$$;

SELECT fn_daily_load(1, CURRENT_DATE)     AS doctor1_today,      -- 2 (cancelled one ignored)
       fn_daily_load(3, CURRENT_DATE)     AS doctor3_today_zero; -- 0

-- ------------------------------------------------------------
-- (c) Procedure: pr_book_appointment
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00'::time, '10:00'::time, '11:00'::time, '12:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot %. Allowed: 09:00, 10:00, 11:00, 12:00', p_slot;
    END IF;

    -- The BEFORE INSERT trigger rejects any clash
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '10:00');   -- succeeds

DO $$
BEGIN
    BEGIN CALL pr_book_appointment(9, 1, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown patient: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 9, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown doctor: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected past date: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected bad slot: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');   -- clash with appointment #1
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected clash (insert): %', SQLERRM; END;
    -- UPDATE moving appointment #2 onto Dr. Mulenga's 09:00 slot must clash
    BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected clash (update): %', SQLERRM; END;
END;
$$;

-- Updating an appointment without moving it is fine (it is excluded from its own clash search)
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
UPDATE appointments SET status = 'BOOKED'   WHERE appointment_id = 1;

-- ------------------------------------------------------------
-- (e) View: v_today_appointments (no unrelated patient data exposed)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- ------------------------------------------------------------
-- (f) Non-unique index
-- Searches filter on appointment_day and doctor_id. A composite B-tree
-- on (appointment_day, doctor_id) answers both conditions in one index
-- lookup. It is non-unique because many appointments share a day/doctor
-- (different slots, cancelled rows).
-- ------------------------------------------------------------
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;   -- replace on rerun
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);     -- rerun: still one row for the date
SELECT * FROM clinic_summary ORDER BY summary_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $cron$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q4_refresh_clinic_summary';
