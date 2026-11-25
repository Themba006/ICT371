-- ============================================================
-- ICT371 Advanced Database - Question 9: Farmer Cooperative Maize Deliveries
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- Rates: grade A K5/kg, grade B K4/kg, grade C K3/kg
-- ============================================================

DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path TO q9_maize, public;

-- ------------------------------------------------------------
-- (a) Database and seed data (tables first)
-- ------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

-- unit_rate and total_value are filled in by the trigger, so inserts may omit them
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Mwape Chola'),
    ('F002', 'Chanda Mwansa'),
    ('F003', 'Thandiwe Banda');

-- ------------------------------------------------------------
-- (b) Function: fn_maize_rate
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE p_grade
                  WHEN 'A' THEN 5.00
                  WHEN 'B' THEN 4.00
                  WHEN 'C' THEN 3.00
              END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (allowed: A, B, C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

SELECT fn_maize_rate('A') AS rate_a, fn_maize_rate('B') AS rate_b, fn_maize_rate('C') AS rate_c;

DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected NULL grade: %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unsupported grade: %', SQLERRM; END;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: one pricing rule for procedure AND direct SQL
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_deliveries_price()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    -- Whatever the caller supplied for rate/value is overwritten
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_before_write
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_deliveries_price();

-- ------------------------------------------------------------
-- (c) Procedure: pr_receive_delivery
-- Inserts only the basic fields; the trigger supplies unit_rate and total_value.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: % (allowed: A, B, C)', p_grade;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: % (must be positive)', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ------------------------------------------------------------
-- (a, continued) Six deliveries, loaded AFTER the trigger was installed.
-- All grades and both payment states are covered.
-- ------------------------------------------------------------
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, CURRENT_DATE - 3, TRUE),
    (1, 'B',  50.50, CURRENT_DATE - 1, FALSE),
    (2, 'C', 200.00, CURRENT_DATE - 1, FALSE),
    (2, 'A',  80.00, CURRENT_DATE - 2, TRUE);

-- Direct SQL that tries to set its own rate/value: the trigger overrides both
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'C', 40.00, 99.00, 1.00, CURRENT_DATE - 2, TRUE);   -- stored as 3.00 and 120.00

-- Loaded through the procedure (is_paid FALSE)
CALL pr_receive_delivery(3, 'B', 25.00, CURRENT_DATE);

-- Mark farmer 3's procedure-loaded delivery as paid, so farmer 3 owes nothing
-- (the UPDATE also passes through the trigger, which re-prices it consistently)
UPDATE deliveries SET is_paid = TRUE
WHERE farmer_id = 3 AND delivered_on = CURRENT_DATE;

SELECT * FROM deliveries ORDER BY delivery_id;

-- Rejections (expect NOTICE messages)
DO $$
BEGIN
    BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown farmer: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected bad grade: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected zero weight: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected negative weight: %', SQLERRM; END;
    BEGIN
        INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
        VALUES (1, 'A', -1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected direct SQL with bad weight: %', SQLERRM; END;
END;
$$;

-- ------------------------------------------------------------
-- (e) View: v_farmer_amount_due (farmers with nothing unpaid show 0)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- farmer F003 shows 0

-- ------------------------------------------------------------
-- (f) Composite index for a farmer's deliveries between two dates
-- Equality on farmer_id first, range on delivered_on second: the index jumps
-- straight to one farmer and reads only the requested dates in order.
-- ------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job: totals are replaced, never added again
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);     -- rerun: same totals, one row
SELECT * FROM daily_purchases ORDER BY purchase_date;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',
    $cron$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q9_refresh_purchases';
