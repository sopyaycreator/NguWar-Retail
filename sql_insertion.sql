-- =====================================================================
-- POS sync fix — migration
-- Run these one block at a time in phpMyAdmin's SQL tab.
-- Take a database export/backup FIRST (Export tab → Quick → Go).
-- =====================================================================


-- ---------------------------------------------------------------------
-- BLOCK 1 — Make item_history a real movement ledger
-- ---------------------------------------------------------------------
-- delta    = the SIGNED change to stock (-2 = sold two, +5 = received five)
--            This is the new source of truth. `qty` stays as-is so your
--            existing history screens keep working.
-- deviceId = which device recorded the movement (for audit + debugging)

ALTER TABLE item_history
  ADD COLUMN deviceId VARCHAR(100) NULL AFTER branch_id,
  ADD COLUMN delta    INT NOT NULL DEFAULT 0 AFTER qty;


-- ---------------------------------------------------------------------
-- BLOCK 2 — Fix a serious multi-tenant bug
-- ---------------------------------------------------------------------
-- Right now clientId is UNIQUE across the WHOLE table, not per shop.
-- Every shop lives in this one database. If two shops ever generate the
-- same clientId, one shop's sale silently overwrites the other's.

ALTER TABLE item_history DROP INDEX uq_history_clientId;
ALTER TABLE item_history ADD UNIQUE KEY uq_history_branch_client (branch_id, clientId);

ALTER TABLE sales DROP INDEX uq_sales_clientId;
ALTER TABLE sales ADD UNIQUE KEY uq_sales_branch_client (branch_id, clientId);


-- ---------------------------------------------------------------------
-- BLOCK 3 — Indexes (your history table is already 3,841 rows and growing)
-- ---------------------------------------------------------------------

ALTER TABLE item_history ADD INDEX idx_hist_branch_barcode (branch_id, barcode, id);
ALTER TABLE item_history ADD INDEX idx_hist_branch_id      (branch_id, id);
ALTER TABLE sync_log     ADD INDEX idx_synclog_branch      (branch_id, id);


-- ---------------------------------------------------------------------
-- BLOCK 4 — Only run this if `isDeleted` is missing from `items`
-- ---------------------------------------------------------------------
-- Your config/db.js CREATE TABLE for `items` does NOT include isDeleted,
-- but routes/sync.js writes to it. It works today only because the live
-- table was altered by hand. A fresh deploy would crash. Check first:
--     SHOW COLUMNS FROM items LIKE 'isDeleted';
-- If it returns nothing, run:

-- ALTER TABLE items ADD COLUMN isDeleted TINYINT(1) NOT NULL DEFAULT 0;

-- Then also add the column to the CREATE TABLE in config/db.js so it
-- matches reality.


-- ---------------------------------------------------------------------
-- BLOCK 5 — OPTIONAL: backfill delta on old rows (cosmetic only)
-- ---------------------------------------------------------------------
-- IMPORTANT: do NOT recompute current stock from history. Your old rows
-- mixed two meanings in `qty` — sales stored a change, but 'Edited Item'
-- and 'Deleted Item' stored an absolute value. That history cannot be
-- replayed reliably.
--
-- Instead: keep whatever items.quantity says today as the opening
-- balance, and apply deltas from now on. Old rows are reference only.
--
-- Your four real action values and what `qty` means in each:
--   Added Item     649   opening stock          → delta = +qty
--   Updated Item  1088   amount added           → delta = +qty
--   Deleted Item   283   stock at deletion      → delta = -qty
--   Edited Item   1821   new ABSOLUTE total     → NOT a delta, leave at 0
--
-- (There is no 'Sale' action — sales have never been written to this
--  table. That is the real root cause, and it is fixed in the app.)

-- UPDATE item_history
-- SET delta = CASE
--       WHEN action IN ('Added Item', 'Updated Item') THEN  ABS(qty)
--       WHEN action = 'Deleted Item'                  THEN -ABS(qty)
--       ELSE 0   -- 'Edited Item' is absolute, not replayable
--     END
-- WHERE delta = 0;