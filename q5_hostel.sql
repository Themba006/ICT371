-- ============================================================
-- ICT371 Advanced Database - Question 5: Hostel Room Allocation
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- ============================================================

DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path TO q5_hostel, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('202301116', 'Brian Phiri'),
    ('202301117', 'Chanda Mwansa'),
    ('202301118', 'Thandiwe Banda'),
    ('202301119', 'Mutale Zulu'),
    ('202301120', 'Natasha Tembo');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),    -- will be full
    ('R102', 3),    -- will be partly occupied
    ('R103', 2);    -- stays empty

-- ------------------------------------------------------------
-- (b) Function: fn_free_beds
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    -- Only ACTIVE allocations occupy beds; ENDED ones are history
    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: enforces the rules for direct SQL changes too
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_allocations_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity   INTEGER;
    v_occupied   INTEGER;
    v_exclude_id INTEGER;
BEGIN
    -- ENDED rows occupy no bed, so there is nothing to enforce
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    -- When updating, do not count the row being changed
    IF TG_OP = 'UPDATE' THEN
        v_exclude_id := OLD.allocation_id;
    ELSE
        v_exclude_id := -1;
    END IF;

    -- Lock the room row so two sessions cannot both take the last bed
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

    -- One ACTIVE allocation per student
    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = NEW.student_id
          AND status = 'ACTIVE'
          AND allocation_id <> v_exclude_id
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    -- Capacity check against the OTHER active allocations in the room
    SELECT COUNT(*) INTO v_occupied
    FROM allocations
    WHERE room_id = NEW.room_id
      AND status = 'ACTIVE'
      AND allocation_id <> v_exclude_id;

    IF v_occupied >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_before_write
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_allocations_rules();

-- ------------------------------------------------------------
-- (c) Procedure: pr_allocate_room
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;

-- ------------------------------------------------------------
-- (a, continued) Allocations: full, partly occupied and empty rooms
-- ------------------------------------------------------------
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- R101 full (2/2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);   -- R102 partly occupied (1/3)

-- History: student 4 previously stayed in R102 and left (does not occupy a bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, CURRENT_DATE - 90, CURRENT_DATE - 45, 'ENDED');
-- R103 has no allocations; student 5 has none either

SELECT fn_free_beds(1) AS r101_free,   -- 0
       fn_free_beds(2) AS r102_free,   -- 2 (the ended row is ignored)
       fn_free_beds(3) AS r103_free;   -- 2

-- Rejections (expect NOTICE messages)
DO $$
BEGIN
    BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected full room (procedure): %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected second ACTIVE allocation: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown student: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown room: %', SQLERRM; END;
    BEGIN PERFORM fn_free_beds(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown room (function): %', SQLERRM; END;

    -- Direct SQL must hit the same rules through the trigger
    BEGIN
        INSERT INTO allocations (student_id, room_id, allocated_on, status)
        VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger blocked direct INSERT into full room: %', SQLERRM; END;
    BEGIN
        INSERT INTO allocations (student_id, room_id, allocated_on, status)
        VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger blocked direct 2nd ACTIVE row: %', SQLERRM; END;
END;
$$;

-- A valid direct update still works: re-saving a row excludes itself from the count
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- ------------------------------------------------------------
-- (e) View: v_room_occupancy (includes rooms with no allocations)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- ------------------------------------------------------------
-- (f) Index for ACTIVE allocations by room
-- A partial index stores only ACTIVE rows. History (ENDED) keeps growing but
-- is never counted for availability, so the index stays small and the
-- capacity check in the trigger/procedure/view reads very few entries.
-- ------------------------------------------------------------
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job: one row per date and room, replaced on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();     -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',
    $cron$CALL q5_hostel.pr_refresh_occupancy()$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q5_refresh_occupancy';
