-- ============================================================
-- ICT371 Advanced Database - Question 6: Monthly Payroll Processing
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- ============================================================

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path TO q6_payroll, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    -- pay_month must be the first day of a month
    CONSTRAINT chk_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Brian Phiri',    8000.00, 1500.00, 1200.00, TRUE),
    ('Chanda Mwansa',  6500.00, 1000.00,  900.00, TRUE),
    ('Thandiwe Banda', 7200.00, 1200.00, 1000.00, TRUE),
    ('Mutale Zulu',    5000.00,  800.00,  700.00, TRUE),    -- will become inactive later
    ('Kelvin Lungu',   4000.00,  500.00,  600.00, FALSE);   -- inactive from the start

-- ------------------------------------------------------------
-- (b) Function: fn_net_pay
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC;
    v_allow NUMERIC;
    v_ded   NUMERIC;
    v_net   NUMERIC;
BEGIN
    SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ------------------------------------------------------------
-- (c) Procedure: pr_process_payroll (query FOR loop)
-- A failed calculation raises an exception, so the WHOLE call rolls back.
-- ON CONFLICT DO NOTHING leaves existing payroll rows unchanged.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec     RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(rec.employee_id);        -- raises on a bad calculation
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: log an actual basic_salary change only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_after_update
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- ------------------------------------------------------------
-- (a, continued) Two payroll months, processed through the procedure
-- ------------------------------------------------------------
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Reprocessing leaves existing rows untouched (no duplicates, no changes)
CALL pr_process_payroll(DATE '2026-10-01');
SELECT pay_month, COUNT(*) AS rows_per_month FROM payroll GROUP BY pay_month ORDER BY pay_month;  -- 4 and 4

SELECT fn_net_pay(1) AS net_pay_employee_1;    -- 8000 + 1500 - 1200 = 8300.00

-- Rejections (expect NOTICE messages)
DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown employee: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(DATE '2026-10-15');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected non month-start date: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected NULL month: %', SQLERRM; END;
END;
$$;

-- Whole-call failure: an employee whose deduction exceeds pay makes the call fail,
-- and nothing for that month is stored.
BEGIN;
    INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
    VALUES ('Test Negative', 100.00, 0.00, 500.00, TRUE);
    DO $$
    BEGIN
        BEGIN CALL pr_process_payroll(DATE '2026-11-01');
        EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END;
    END;
    $$;
    SELECT COUNT(*) AS nov_rows_stored FROM payroll WHERE pay_month = DATE '2026-11-01';   -- 0
ROLLBACK;   -- remove the test employee

-- Trigger demonstration
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;                -- logged
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;        -- NOT logged
UPDATE employees SET allowance = allowance + 100 WHERE employee_id = 3;        -- NOT logged
SELECT * FROM salary_audit ORDER BY audit_id;                                  -- exactly 1 row

-- Employee 4 leaves: becomes inactive, but history must remain visible in the report
UPDATE employees SET active = FALSE WHERE employee_id = 4;

-- ------------------------------------------------------------
-- (e) View: v_payroll_report (no filter on active, so history is kept)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;   -- Mutale Zulu still appears

-- ------------------------------------------------------------
-- (f) Index for a report filtered by pay_month across all employees
-- The existing UNIQUE (employee_id, pay_month) index starts with employee_id,
-- so it cannot be used efficiently to find a month for ALL employees. An index
-- on pay_month alone serves that report and does not duplicate the unique one.
-- ------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job: 02:00 on the 1st of each month, for the previous month
-- ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q6_process_payroll',
    '0 2 1 * *',
    $cron$CALL q6_payroll.pr_process_payroll(
              (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date
          )$cron$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_process_payroll';

-- Inspect the run history (rows appear after the job has run)
SELECT jobid, runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_process_payroll')
ORDER BY start_time DESC;
