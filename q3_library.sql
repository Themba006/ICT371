-- ============================================================
-- ICT371 Advanced Database - Question 3: Library Returns and Overdue Fines
-- Student: Brian Phiri (202301116)
-- DBMS: PostgreSQL 12+ (pg_cron for scheduling)
-- ============================================================

DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path TO q3_library, public;

-- ------------------------------------------------------------
-- (a) Database and seed data
-- ------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE NULL,
    new_returned_on  DATE NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- ------------------------------------------------------------
-- (b) Function: fn_loan_fine  (K2 per overdue day, minimum zero)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- Earlier of p_as_of and returned_on (LEAST ignores NULL when not returned)
    v_end := LEAST(p_as_of, v_returned);

    -- Returning on the due date gives 0 days; never negative
    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$;

-- ------------------------------------------------------------
-- (c) Procedure: pr_return_loan
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_borrowed;
    END IF;

    -- Final fine is calculated as at the return date
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    -- Return date and final fine are stored together in ONE statement
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- ------------------------------------------------------------
-- (d) Trigger: log returned_on changes only
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loans_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_after_update
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loans_audit();

-- ------------------------------------------------------------
-- (a, continued) Six loans
-- ------------------------------------------------------------
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mwansa',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
    (2, 'Mutale Phiri',   CURRENT_DATE - 10, CURRENT_DATE + 4),   -- 2 open, on time
    (3, 'Thandiwe Banda', CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 3 will be returned late
    (1, 'Bwalya Zulu',    CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 4 will be returned on due date
    (2, 'Natasha Tembo',  CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 5 open, overdue
    (3, 'Kelvin Lungu',   CURRENT_DATE - 5,  CURRENT_DATE + 9);   -- 6 open, on time

-- Returns go through the procedure so the trigger logs them
CALL pr_return_loan(3, CURRENT_DATE - 5);    -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- on due date  -> K0

SELECT loan_id, borrower_name, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;   -- exactly 2 rows

-- Function checks
SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue_fine,   -- 32
       fn_loan_fine(2, CURRENT_DATE) AS not_yet_due,         -- 0
       fn_loan_fine(3, CURRENT_DATE) AS returned_loan_fine,  -- 12 (stops at return date)
       fn_loan_fine(4, CURRENT_DATE) AS returned_on_due;     -- 0

-- Rejections (expect NOTICE messages)
DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected unknown loan: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected already returned: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(1, CURRENT_DATE - 60);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected return before borrow: %', SQLERRM; END;
END;
$$;

-- Unchanged returned_on must NOT create an audit row
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 1;
SELECT count(*) AS audit_rows_still_2 FROM loan_audit;

-- ------------------------------------------------------------
-- (e) View: v_overdue_loans
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- ------------------------------------------------------------
-- (f) Index for "a given book's unreturned loans"
-- A partial index holds only unreturned loans (a small, hot subset of a
-- table that grows forever), so it stays small and the lookup is fast.
-- ------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- demonstration only: tables are tiny
EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- ------------------------------------------------------------
-- (g) Scheduled job
-- Counts loans still unreturned as at p_as_of (never returned, or returned
-- after that date) that are overdue on that date, and sums their fines.
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;     -- replace on rerun
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);               -- rerun: still one row
SELECT * FROM overdue_summary ORDER BY snapshot_date;   -- expect count 2, fine 84

CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',
    $cron$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$cron$
);

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q3_refresh_overdue';
