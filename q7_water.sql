-- ============================================================
-- ICT371 Advanced Database - Question 7: Water Meter Readings and Billing
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- Tariff: first 10 units K5 each, units above 10 K8 each
-- ============================================================

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path TO q7_water, public;

-- ------------------------------------------------------------
-- (a) Database and seed data (tables first)
-- ------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES
    ('Brian Phiri'), ('Chanda Mwansa'), ('Thandiwe Banda');

-- ------------------------------------------------------------
-- (d) Trigger: reject current_reading below previous_reading
-- Installed before readings are loaded so direct SQL imports are checked too.
-- A BEFORE trigger that raises an exception stops the row from being stored.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_readings_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_before_write
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_readings_check();

-- Six readings: zero units, exactly 10 units and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100),   -- 0 units
    (1, DATE '2026-10-01', 100, 110),   -- 10 units (exactly)
    (2, DATE '2026-09-01',  50,  65),   -- 15 units
    (2, DATE '2026-10-01',  65,  70),   -- 5 units
    (3, DATE '2026-09-01', 200, 230),   -- 30 units
    (3, DATE '2026-10-01', 230, 240);   -- 10 units (exactly)

-- Direct SQL import with a bad reading must be rejected and not stored
DO $$
BEGIN
    BEGIN
        INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
        VALUES (1, DATE '2026-11-01', 110, 90);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected bad reading: %', SQLERRM; END;
    BEGIN
        UPDATE readings SET current_reading = 1 WHERE reading_id = 2;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected bad update: %', SQLERRM; END;
END;
$$;
SELECT COUNT(*) AS readings_stored FROM readings;   -- still 6

-- ------------------------------------------------------------
-- (b) Function: fn_water_charge
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be zero or more)', p_units;
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);   -- exact two-decimal charge
END;
$$;

SELECT fn_water_charge(0)  AS units_0,    -- 0.00
       fn_water_charge(10) AS units_10,   -- 50.00
       fn_water_charge(15) AS units_15,   -- 90.00
       fn_water_charge(30) AS units_30;   -- 210.00

DO $$
BEGIN
    BEGIN PERFORM fn_water_charge(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected NULL: %', SQLERRM; END;
    BEGIN PERFORM fn_water_charge(-3);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected negative: %', SQLERRM; END;
END;
$$;

-- ------------------------------------------------------------
-- (c) Procedure: pr_generate_bill
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC;
    v_curr   NUMERIC;
    v_units  NUMERIC;
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- Generate bills (some already past due, some not yet due)
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 40);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 40);
CALL pr_generate_bill(6, CURRENT_DATE - 10);

-- Rejections
DO $$
BEGIN
    BEGIN CALL pr_generate_bill(99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown reading: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected duplicate bill: %', SQLERRM; END;
END;
$$;

-- Record some payments
UPDATE bills SET amount_paid = charge WHERE reading_id = 1;   -- zero-charge bill, fully settled
UPDATE bills SET amount_paid = charge WHERE reading_id = 2;   -- paid in full
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;   -- part payment of 90

SELECT * FROM bills ORDER BY bill_id;

-- ------------------------------------------------------------
-- (e) View: v_overdue_bills
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;

-- ------------------------------------------------------------
-- (f) Index for date-based searches of overdue bills
-- A partial index on due_on that holds ONLY unpaid bills. Paid bills make up
-- most of the table over time and are never searched for overdue work, so the
-- index stays small, and date comparisons (due_on < today) use it directly.
-- ------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;      -- replace the same date's total
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                   -- rerun: still one row, same total
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $cron$CALL q7_water.pr_refresh_receivables()$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q7_refresh_receivables';
