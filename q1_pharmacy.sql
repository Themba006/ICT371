-- ============================================================
-- ICT371 Advanced Database - Question 1: Pharmacy Stock and Daily Sales
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- Run the whole file top to bottom. It is safe to re-run.
-- ============================================================

DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path TO q1_pharmacy, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Medicines are seeded now; sales are loaded later through pr_record_sale.
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('Ibuprofen 400mg',   3.75,  12);

-- ------------------------------------------------------------
-- (b) Function: fn_sale_value
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ------------------------------------------------------------
-- (c) Procedure: pr_record_sale
-- Any RAISE EXCEPTION rolls the whole call back, so an invalid
-- sale leaves both sales and medicines unchanged.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    -- Lock the row so two sales cannot oversell the same stock
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
            p_medicine_id, p_quantity, v_stock;
    END IF;

    -- Store the CURRENT price in the sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, COALESCE(p_sold_on, CURRENT_DATE));

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: log OLD and NEW stock only when it really changes
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_after_update
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_medicines_stock_audit();

-- ------------------------------------------------------------
-- (a, continued) Six valid sales loaded through the procedure
-- ------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(3,  1, CURRENT_DATE);

-- Proof that the function works
SELECT fn_sale_value(2, 4) AS value_of_4_amoxicillin;   -- expect 32.00

-- Proof that an invalid sale changes nothing (expect NOTICE messages)
DO $$
BEGIN
    BEGIN
        CALL pr_record_sale(3, 999, CURRENT_DATE);   -- more than the stock
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Rejected as expected: %', SQLERRM;
    END;
    BEGIN
        CALL pr_record_sale(99, 1, CURRENT_DATE);    -- unknown medicine
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Rejected as expected: %', SQLERRM;
    END;
END;
$$;

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;   -- one row per deduction

-- Trigger must NOT log when stock does not change:
UPDATE medicines SET stock_qty = stock_qty WHERE medicine_id = 1;
UPDATE medicines SET unit_price = unit_price WHERE medicine_id = 1;
SELECT count(*) AS audit_rows_unchanged FROM stock_audit;   -- same count as above

-- ------------------------------------------------------------
-- (e) View: v_low_stock
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view after a sale
CALL pr_record_sale(3, 1, CURRENT_DATE);   -- Ibuprofen drops further
SELECT * FROM v_low_stock;

-- ------------------------------------------------------------
-- (f) Index
-- Composite (medicine_id, sold_on): equality on medicine_id first,
-- then a range on sold_on, so one index scan returns exactly one
-- medicine's sales in the date window, already ordered by date.
-- ------------------------------------------------------------
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);
ANALYZE sales;

-- The tables are tiny, so the planner would normally pick a sequential
-- scan. We switch it off only to demonstrate that the index is usable.
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job
-- UPSERT makes reruns idempotent: totals are replaced, never added.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Run twice for the same day: the result must be identical (no double counting)
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;

-- Schedule daily at 00:15 for the previous day (pg_cron uses UTC by default)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q1_refresh_sales',
    '15 0 * * *',
    $cron$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q1_refresh_sales';
