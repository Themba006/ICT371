-- ============================================================
-- ICT371 Advanced Database - Question 8: Transport Fleet Maintenance
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- Service rule: due when current_odometer - last_service_odometer >= 5000 km
-- ============================================================

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path TO q8_fleet, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles at different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ZM 101 AA', 12000, 10000),   -- 2000 km since service (not due)
    ('ZM 202 BB', 20000, 14000),   -- 6000 km since service (due)
    ('ZM 303 CC',  5000,     0);   -- exactly 5000 km since service (due, on the boundary)

-- ------------------------------------------------------------
-- (b) Function: fn_service_due
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

SELECT fn_service_due(1) AS v1_not_due,    -- false
       fn_service_due(2) AS v2_due,        -- true
       fn_service_due(3) AS v3_boundary;   -- true (exactly 5000)

-- ------------------------------------------------------------
-- (c) Procedure: pr_record_trip
-- It does NOT touch the vehicle odometer; the trigger does that.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: BEFORE INSERT on trips
-- Validates start = current odometer, rejects invalid mileage, and
-- moves current_odometer to the trip end exactly once.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_trips_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle row so concurrent trips cannot reuse the same start value
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must be greater than start (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match the vehicle''s current odometer %',
            NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trips_before_insert();

-- ------------------------------------------------------------
-- (a, continued) Six trips, added through the procedure AFTER the trigger exists
-- ------------------------------------------------------------
CALL pr_record_trip(1, CURRENT_DATE - 10, 12000, 12300);
CALL pr_record_trip(1, CURRENT_DATE -  8, 12300, 12800);
CALL pr_record_trip(2, CURRENT_DATE -  9, 20000, 20400);
CALL pr_record_trip(2, CURRENT_DATE -  6, 20400, 21000);
CALL pr_record_trip(3, CURRENT_DATE -  7,  5000,  5200);
CALL pr_record_trip(3, CURRENT_DATE -  3,  5200,  5500);

SELECT * FROM vehicles ORDER BY vehicle_id;   -- odometers: 12800, 21000, 5500
SELECT * FROM trips ORDER BY trip_id;

-- Rejections (expect NOTICE messages; odometers stay unchanged)
DO $$
BEGIN
    BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown vehicle: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12800);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected end = start: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12000);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected end < start: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13000, 13100);   -- start does not match 12800
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected wrong start odometer: %', SQLERRM; END;
    BEGIN PERFORM fn_service_due(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown vehicle (function): %', SQLERRM; END;
END;
$$;
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY vehicle_id;   -- unchanged

-- ------------------------------------------------------------
-- (e) View: v_service_due
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;   -- ZM 202 BB (7000) and ZM 303 CC (5500)

-- ------------------------------------------------------------
-- (f) Index for one vehicle's trips within a trip_on date range
-- Composite (vehicle_id, trip_on): equality on vehicle_id first, then a range
-- on trip_on, so the query reads just that vehicle's trips in the window,
-- already sorted by date, with no scan of other vehicles' trips.
-- ------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_tripon ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_service_alerts
-- Insert/update one alert per due vehicle, remove alerts for vehicles that
-- are no longer due. flagged_on keeps the date the alert was first raised.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts a
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = a.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();         -- rerun: still one alert per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- vehicles 2 and 3

-- Servicing vehicle 2 removes its alert on the next refresh
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- only vehicle 3 remains

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 06:00
SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',
    $cron$CALL q8_fleet.pr_refresh_service_alerts()$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q8_refresh_service_alerts';
