-- ============================================================
-- ICT371 Advanced Database - Question 2: University Fee Payments
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- ============================================================

DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path TO q2_fees, public;

-- ------------------------------------------------------------
-- (a) Database and seed data (tables and constraints first)
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Three students with different fee balances.
-- Student 3 will have no payments at all.
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202301116', 'Brian Phiri',    5000.00),
    ('202301117', 'Chanda Mwansa',  3000.00),
    ('202301118', 'Thandiwe Banda', 4500.00);

-- ------------------------------------------------------------
-- (b) Function: fn_fee_balance
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- COALESCE returns the full fee when the student has no payments
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: the audit row is written by the trigger, never by the procedure
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payments_audit();

-- ------------------------------------------------------------
-- (c) Procedure: pr_receive_payment
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;

    -- Lock the student row so two simultaneous payments cannot overpay
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    -- fee_due is NOT changed; the balance is derived from payments
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;

-- ------------------------------------------------------------
-- (a, continued) Six payments loaded through the procedure
-- Student 1 (fee 5000): pays 3 times, balance becomes 2000
-- Student 2 (fee 3000): pays 3 times, fully settled
-- Student 3 (fee 4500): no payments
-- ------------------------------------------------------------
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(2,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500, CURRENT_DATE - 1);

SELECT fn_fee_balance(1) AS balance_student_1,   -- 2000.00
       fn_fee_balance(2) AS balance_student_2,   -- 0.00
       fn_fee_balance(3) AS balance_student_3;   -- 4500.00 (no payments)

-- Rejections (expect NOTICE messages, no rows added)
DO $$
BEGIN
    BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected NULL: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected zero: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected negative: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 99999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected overpayment: %', SQLERRM; END;
    BEGIN PERFORM fn_fee_balance(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown student: %', SQLERRM; END;
END;
$$;

SELECT * FROM students ORDER BY student_id;        -- fee_due unchanged
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;     -- 6 rows written by the trigger

-- ------------------------------------------------------------
-- (e) View: v_fee_balances (settled students are excluded)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;   -- Chanda Mwansa (settled) must not appear

-- ------------------------------------------------------------
-- (f) Composite index
-- student_id is tested with equality and paid_on with a range, so
-- (student_id, paid_on) lets PostgreSQL jump to one student and then
-- scan only the requested date range in order.
-- ------------------------------------------------------------
CREATE INDEX idx_payments_student_paidon ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;   -- replace, not add
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);       -- rerun replaces the row
SELECT * FROM daily_collections ORDER BY collection_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',
    $cron$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q2_refresh_collections';
