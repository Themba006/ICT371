-- ============================================================
-- ICT371 Advanced Database - Question 10: Scholarship Application Assessment
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- Rule: qualify only if age 18-25 (inclusive), monthly income <= K3,000,
--       and average mark >= 70
-- ============================================================

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path TO q10_scholarship, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202301116', 'Brian Phiri'),
    ('202301117', 'Chanda Mwansa'),
    ('202301118', 'Thandiwe Banda');

-- Six PENDING applications across three students: qualifying, non-qualifying
-- and boundary cases.
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2500.00, 85.00, CURRENT_DATE - 12, 'PENDING'),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 10, 'PENDING'),   -- 2 qualifies: every lower/upper boundary
    (2, 25, 1000.00, 90.00, CURRENT_DATE -  8, 'PENDING'),   -- 3 qualifies: upper age boundary
    (2, 26, 1000.00, 90.00, CURRENT_DATE -  6, 'PENDING'),   -- 4 fails: age 26
    (3, 22, 3000.01, 80.00, CURRENT_DATE -  4, 'PENDING'),   -- 5 fails: income just over K3,000
    (3, 21, 2000.00, 69.99, CURRENT_DATE -  2, 'PENDING');   -- 6 fails: mark just under 70

-- ------------------------------------------------------------
-- (b) Function: fn_scholarship_eligible
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

SELECT fn_scholarship_eligible(20, 2500, 85)    AS qualifies,         -- true
       fn_scholarship_eligible(18, 3000, 70)    AS all_boundaries,    -- true
       fn_scholarship_eligible(25, 1000, 90)    AS age_25,            -- true
       fn_scholarship_eligible(26, 1000, 90)    AS age_26,            -- false
       fn_scholarship_eligible(22, 3000.01, 80) AS income_over,       -- false
       fn_scholarship_eligible(21, 2000, 69.99) AS mark_under;        -- false

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected NULL: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected age 0: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected negative income: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected mark 101: %', SQLERRM; END;
END;
$$;

-- ------------------------------------------------------------
-- (c) Procedure: pr_assess_application
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC;
    v_mark     NUMERIC;
    v_status   VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN
    -- Lock the row so the same application cannot be assessed twice at once
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: record actual status changes only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_after_update
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- Demonstrate the procedure and trigger on application 1 and 4
CALL pr_assess_application(1);    -- APPROVED
CALL pr_assess_application(4);    -- REJECTED

DO $$
BEGIN
    BEGIN CALL pr_assess_application(1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected already assessed: %', SQLERRM; END;
    BEGIN CALL pr_assess_application(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown application: %', SQLERRM; END;
END;
$$;

-- An UPDATE that leaves status unchanged must NOT create an audit row
UPDATE applications SET status = status WHERE application_id = 2;
UPDATE applications SET average_mark = average_mark WHERE application_id = 2;

SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;     -- exactly 2 rows (apps 1 and 4)

-- ------------------------------------------------------------
-- (e) View: v_approved_applicants (income deliberately omitted)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- ------------------------------------------------------------
-- (f) Index for status within a submitted_on date range
-- Composite (status, submitted_on): the equality column (status) comes first
-- and the range column (submitted_on) second, so the index narrows to one
-- status and then reads only the requested dates in order.
-- ------------------------------------------------------------
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job: pr_assess_pending (query FOR loop, PENDING only)
-- Completed applications are never selected, so a rerun cannot reassess them
-- or duplicate audit entries.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();      -- assesses the 4 remaining PENDING applications
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
-- Expected: 1,2,3 APPROVED; 4,5,6 REJECTED

SELECT COUNT(*) AS audit_rows_after_first_run FROM decision_audit;    -- 6

CALL pr_assess_pending();      -- rerun: nothing is PENDING, so nothing happens
SELECT COUNT(*) AS audit_rows_after_rerun FROM decision_audit;        -- still 6

SELECT * FROM v_approved_applicants ORDER BY student_number;          -- income not shown

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 08:00
SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',
    $cron$CALL q10_scholarship.pr_assess_pending()$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q10_assess_pending';
