# nguwar

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
# POS multi-device stock fix — deployment guide

## What was wrong

Devices sent their **absolute** stock total. Whoever synced last won.

```
Start: 10
Device A sells 2 → pushes "quantity: 8"
Device B sells 1 → pushes "quantity: 9"   ← overwrites A
Result: 9        (should be 7)
```

Three separate problems fed it:

1. `sync.js` did `ON DUPLICATE KEY UPDATE quantity = VALUES(quantity)` — a blind overwrite.
2. **Sales never wrote to `item_history` at all.** 3,841 history rows, zero of them a sale. Stock left the shelf and the ledger never knew.
3. `item_history.qty` meant different things per action — a change for `Updated Item`, an absolute total for `Edited Item` — so the history couldn't be replayed even if you wanted to.

## What changed

Stock is never assigned. It is only added to.

```
WRONG:  UPDATE items SET quantity = 8
RIGHT:  UPDATE items SET quantity = quantity + (-2)
```

Devices report what happened (`delta: -2`). The server adds them up. `10 - 2 - 1 = 7`, and sync order stops mattering, because addition doesn't care who goes first.

Retries are safe because every movement carries a device-generated `clientId` and the server uses `INSERT IGNORE`. This matters more than it looks: your client's 120s timeout is shorter than the server's 180s, so a "failed" batch has often actually committed, and `_syncIndividually` re-sends it.

---

## Deployment order

**Do these in order. Do not skip step 1.**

### 1. Database migration

Export a backup first (phpMyAdmin → Export → Quick → Go). Then run `server/01_migration.sql` block by block. It's additive — nothing is dropped except two indexes that are immediately recreated correctly.

Block 4 is conditional: check `SHOW COLUMNS FROM items LIKE 'isDeleted';` first. Your `config/db.js` `CREATE TABLE` for `items` is missing this column even though `sync.js` writes to it — it only works today because the live table was altered by hand. Add it to `config/db.js` too, or a fresh deploy will crash.

### 2. Server

Replace `routes/sync.js` and `routes/items.js`.

Safe to deploy before the app. Devices that don't send `syncVersion: 2` get the old absolute behaviour, so nothing breaks mid-rollout.

### 3. App

Replace `lib/db_helper.dart` and `lib/sync_service.dart`, then **update every device**. You have 4 users — do them all in one sitting if you can.

While a device is still on the old build it keeps corrupting stock exactly as before. The compatibility path stops it getting *worse*, not from being wrong.

### 4. Reconcile

Your current numbers are already wrong, and you cannot recompute them — sales were never in the history table, so there's nothing to replay. After everyone is updated, do a physical count and push it through `applyStockTake()`. Everything after that baseline will add up.

---

## main.dart

`lib/main_dart_changes.dart` has the replacement methods. `main.dart` is ~2,000 lines and most of it is UI, so that file contains only what changes:

1. **`_confirmCheckoutAndDeduct()`** — the bug site. Now calls `insertSaleWithStock()`.
2. **`_showEditItemDialog()`** — pass `baselineQuantity`.
3. **`_fillDrawerWithMatchedItem()`** — stop pre-filling current stock into the Add box.
4. **Quantity field label** — "Quantity to Add" instead of "Quantity Stock".
5. **Sync call sites** — use `synchronize()` rather than push-then-pull by hand.

Items 3 and 4 are a separate bug worth understanding. The drawer's quantity box has always meant "how many are arriving" — the old `insertOrUpdateItem` did `currentQty + incomingQty`. But `_fillDrawerWithMatchedItem` pre-filled it with the item's *current* stock. Scan an item with 10 in stock, press Save, and you get 20.

That's very likely where a good share of your 1,821 `Edited Item` rows came from: staff correcting stock the Add drawer had just doubled.

### Reference: what replaces what

| Situation | Call |
|---|---|
| Completed sale | `insertSaleWithStock(sale: ..., lines: [...])` |
| Refund / void | `voidSale(lines: [...])` |
| Stock received | `insertOrUpdateItem({... 'quantity': amountArriving})` |
| Manual correction | `updateItemOnly(..., baselineQuantity: shown)` |
| Physical recount | `applyStockTake(...)` |

Deleting `updateItemQuantity` rather than deprecating it is deliberate — the compiler shows you every place stock moves, and you want that list short and visible.

### Files I have now reviewed

**`transaction_history_page.dart`** — no changes needed. It's read-only: `getSaleDateSummary`, `getSalesByDate`, `getSaleDateSummariesPaginated`. Nothing deletes a sale, so there's no path that could strand stock.

One loose end: it takes an `isUnlocked` parameter that's never used in the body. `main.dart` makes the user enter the admin PIN to reach this page, so the PIN gate currently protects a screen that has no privileged actions. Harmless, but if you were planning to add sale deletion behind that flag, see the warning below first.

**`item_history_page.dart`** — replaced. Two reasons:

- Sales appear in this list for the first time. There were zero before, and the icon logic (`action == 'Added Item' ? add_box : edit_note`) gave every sale a generic blue edit icon.
- `qty` is now always positive; direction lives in `delta`. A sale of 2 rendered as "Qty: 2" with no sign that stock left.

The new version reads direction from `delta`, colours movements in and out differently, and shows a **Net** figure per day — the number that should reconcile against a physical count. Rows written before the migration fall back to the same action mapping the server uses, so old history still renders sensibly.

### Warning: `deleteSale()`

`DBHelper.deleteSale(int id)` exists and nothing currently calls it. Leave it that way, or fix it first — as written it deletes the sale row locally only. It doesn't queue anything for the server, and it doesn't return the stock. Delete a sale and the items stay sold forever with no receipt explaining where they went.

If you add sale deletion later, it needs to call `voidSale()` with the sale's line items and queue the removal. That means storing the lines in a structured form; right now `sales.type` is a display string like `"2x Coke, 1x Lays"`, which you'd have to parse back out — the same regex `transaction_history_page.dart` already uses for its item totals. A `sale_lines` table would be the cleaner answer if this becomes a real feature.

---

## Other bugs fixed along the way

- **Every device reported the same ID.** `'flutter-device-$branchId'` meant A and B were indistinguishable in `sync_log`, which is part of why this stayed invisible. Each install now stores a permanent UUID in a new `app_meta` table.
- **Infinite sync loop.** `markQueueError` only printed. The row stayed pending, `continue` re-fetched the same batch, forever, hammering the server. It now counts attempts and parks a row after 5 failures. `recoverFailedTransactions()` un-parks them.
- **Local catalogue wipe.** `pullFromServer` hard-deleted any local item missing from the server's list. One `success: true` with an empty array would have emptied every device. Now guarded.
- **`_isSyncing` could stick.** It was cleared in each catch block separately; an unexpected return path left it `true` and blocked all later syncs. Moved to `finally`.
- **Pull-during-pending.** Pulling with unsynced rows in the queue overwrote local stock with totals that didn't include this device's sales. Now refuses.
- **`clientId` was globally unique, not per shop.** Every shop shares one database. Two shops generating the same clientId meant one silently overwrote the other. Fixed to `(branch_id, clientId)`.

---

## Not fixed — worth your attention

**Your multi-tenancy has a hole.** `apiKey = 'nguwar-pos-my-secret-2026'` is hardcoded in the APK, and `branchId` comes from the URL. Anyone who decompiles one app can call `/api/<any-other-shop>/items` and read or wipe another shop's data. You issue a JWT at login and then never verify it.

The fix is roughly 20 lines: verify the JWT in middleware, take `branchId` from the verified token, and ignore the URL parameter. Worth doing before you onboard shop number five.

**`connectionLimit: 3`** with per-row query loops is why you needed 180-second timeouts. Batch the inserts once correctness is settled.

**`routes/branches.js` is dead code** — it scans `information_schema` for `pos_*` databases, but you moved to a single shared DB. It returns an empty list. Delete it or rewrite as `SELECT DISTINCT branch_id FROM users`.