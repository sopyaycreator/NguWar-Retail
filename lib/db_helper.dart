import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'shop_time.dart';

/// ---------------------------------------------------------------------------
/// THE ONE RULE THIS FILE ENFORCES
///
/// Stock is never ASSIGNED. It is only ADDED TO.
///
///   WRONG:  UPDATE items SET quantity = 8
///   RIGHT:  UPDATE items SET quantity = quantity + (-2)
///
/// The device reports what happened (a signed delta). The server adds the
/// deltas from every device together. Two offline devices can then both be
/// right, and the order they sync in stops mattering.
///
/// Every stock change goes through recordStockMovement(). If you add a new
/// feature that moves stock, it goes through there too — no exceptions, or
/// that path will silently lose data on multi-device shops.
/// ---------------------------------------------------------------------------
class DBHelper {
  static Database? _db;

  static const int _dbVersion = 10;
  static const String defaultBranchId = 'nguwar_1';

  /// A queue row is parked after this many failed attempts, so one bad
  /// payload can't block everything behind it forever.
  static const int maxSyncAttempts = 5;

  static final Uuid _uuid = Uuid();

  static String _newClientId(String prefix) => '$prefix-${_uuid.v4()}';

  static String _now() => DateTime.now().toUtc().toIso8601String();

  // =========================================================================
  // SCHEMA
  // =========================================================================

  static Future<bool> _hasColumn(
    Database db,
    String tableName,
    String columnName,
  ) async {
    final columns = await db.rawQuery("PRAGMA table_info($tableName)");
    return columns.any((col) => col['name'] == columnName);
  }

  static Future<void> _ensureSyncIdentityColumns(Database db) async {
    if (!await _hasColumn(db, 'sales', 'serverId')) {
      await db.execute('ALTER TABLE sales ADD COLUMN serverId INTEGER');
    }
    if (!await _hasColumn(db, 'sales', 'clientId')) {
      await db.execute('ALTER TABLE sales ADD COLUMN clientId TEXT');
    }
    if (!await _hasColumn(db, 'item_history', 'serverId')) {
      await db.execute('ALTER TABLE item_history ADD COLUMN serverId INTEGER');
    }
    if (!await _hasColumn(db, 'item_history', 'clientId')) {
      await db.execute('ALTER TABLE item_history ADD COLUMN clientId TEXT');
    }

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_server_id
      ON sales(serverId) WHERE serverId IS NOT NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_client_id
      ON sales(clientId) WHERE clientId IS NOT NULL AND clientId != ''
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_history_server_id
      ON item_history(serverId) WHERE serverId IS NOT NULL
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_history_client_id
      ON item_history(clientId) WHERE clientId IS NOT NULL AND clientId != ''
    ''');
  }

  /// v10 additions: the ledger's delta column, queue retry tracking, and a
  /// meta table so this install gets a stable unique device id.
  static Future<void> _ensureV10Columns(Database db) async {
    if (!await _hasColumn(db, 'item_history', 'delta')) {
      await db.execute(
        'ALTER TABLE item_history ADD COLUMN delta INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!await _hasColumn(db, 'sync_queue', 'attempts')) {
      await db.execute(
        'ALTER TABLE sync_queue ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (!await _hasColumn(db, 'sync_queue', 'lastError')) {
      await db.execute('ALTER TABLE sync_queue ADD COLUMN lastError TEXT');
    }

    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_meta(
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  static Future<Database> get database async {
    if (_db != null) return _db!;

    _db = await openDatabase(
      join(await getDatabasesPath(), 'pos_inventory.db'),
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createTables(db);
        await _ensureSyncIdentityColumns(db);
        await _ensureV10Columns(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _ensureItemColumns(db);

        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS item_history(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              itemName TEXT,
              barcode TEXT,
              action TEXT,
              qty INTEGER,
              createdAt TEXT
            )
          ''');
        }

        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_queue(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              entityType TEXT,
              operation TEXT,
              payload TEXT,
              branchId TEXT,
              createdAt TEXT,
              synced INTEGER DEFAULT 0
            )
          ''');
        }

        if (oldVersion < 6) {
          try {
            await db.execute(
              'ALTER TABLE sales ADD COLUMN serverId INTEGER UNIQUE',
            );
          } catch (_) {}
        }

        if (oldVersion < 7) {
          try {
            await db.execute(
              'ALTER TABLE item_history ADD COLUMN serverId INTEGER UNIQUE',
            );
          } catch (_) {}
        }

        if (oldVersion < 8) {
          await _ensureSyncIdentityColumns(db);
        }

        if (oldVersion < 9) {
          try {
            await db.execute(
              'ALTER TABLE items ADD COLUMN isDeleted INTEGER DEFAULT 0',
            );
          } catch (_) {}
        }

        if (oldVersion < 10) {
          await _ensureV10Columns(db);
        }
      },
    );

    return _db!;
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE items(
        barcode TEXT PRIMARY KEY,
        name TEXT,
        quantity INTEGER DEFAULT 0,
        priceUnit REAL,
        trackStock INTEGER DEFAULT 1,
        saleEffect INTEGER DEFAULT 1,
        isDeleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sales(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serverId INTEGER UNIQUE,
        clientId TEXT UNIQUE,
        type TEXT,
        price REAL,
        saleDate TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE item_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serverId INTEGER UNIQUE,
        clientId TEXT UNIQUE,
        itemName TEXT,
        barcode TEXT,
        action TEXT,
        qty INTEGER,
        delta INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_queue(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entityType TEXT,
        operation TEXT,
        payload TEXT,
        branchId TEXT,
        createdAt TEXT,
        synced INTEGER DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        lastError TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE app_meta(
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  static Future<void> _ensureItemColumns(Database db) async {
    final columns = await db.rawQuery("PRAGMA table_info(items)");
    final names = columns.map((c) => c['name']).toSet();

    if (!names.contains('trackStock')) {
      await db.execute(
        'ALTER TABLE items ADD COLUMN trackStock INTEGER DEFAULT 1',
      );
    }
    if (!names.contains('saleEffect')) {
      await db.execute(
        'ALTER TABLE items ADD COLUMN saleEffect INTEGER DEFAULT 1',
      );
    }
    if (!names.contains('isDeleted')) {
      await db.execute(
        'ALTER TABLE items ADD COLUMN isDeleted INTEGER DEFAULT 0',
      );
    }
  }

  // =========================================================================
  // DEVICE IDENTITY
  //
  // Previously every device reported 'flutter-device-$branchId', so Device A
  // and Device B were indistinguishable in sync_log — which is part of why
  // this bug was invisible. Each install now gets its own permanent id.
  // =========================================================================

  static String? _cachedDeviceId;

  static Future<String> getDeviceId() async {
    if (_cachedDeviceId != null) return _cachedDeviceId!;

    final db = await database;
    final rows = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: ['deviceId'],
      limit: 1,
    );

    if (rows.isNotEmpty && (rows.first['value']?.toString() ?? '').isNotEmpty) {
      _cachedDeviceId = rows.first['value'].toString();
      return _cachedDeviceId!;
    }

    final generated = 'dev-${_uuid.v4()}';
    await db.insert('app_meta', {
      'key': 'deviceId',
      'value': generated,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _cachedDeviceId = generated;
    return generated;
  }

  // =========================================================================
  // SYNC QUEUE
  // =========================================================================

  static Future<void> _insertSyncQueue(
    DatabaseExecutor executor, {
    required String entityType,
    required String operation,
    required Map<String, dynamic> payload,
    required String branchId,
  }) async {
    await executor.insert('sync_queue', {
      'entityType': entityType,
      'operation': operation,
      'payload': jsonEncode(payload),
      'branchId': branchId,
      'createdAt': _now(),
      'synced': 0,
      'attempts': 0,
    });
  }

  static Future<void> enqueueSync({
    required String entityType,
    required String operation,
    required Map<String, dynamic> payload,
    required String branchId,
  }) async {
    final db = await database;
    await _insertSyncQueue(
      db,
      entityType: entityType,
      operation: operation,
      payload: payload,
      branchId: branchId,
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingSyncQueue(
    String branchId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'sync_queue',
      where: 'branchId = ? AND synced = 0',
      whereArgs: [branchId],
      orderBy: 'createdAt ASC, id ASC',
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<void> markQueueSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE sync_queue SET synced = 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  /// Records a failure and parks the row once it has failed too often.
  ///
  /// The old version only printed. Because the row stayed pending, the sync
  /// loop re-fetched the same batch and retried forever — an infinite loop
  /// that hammered the server. Parking (synced = -1) lets the queue drain.
  static Future<void> markQueueError(int id, String errorMsg) async {
    final db = await database;

    await db.rawUpdate(
      'UPDATE sync_queue SET attempts = attempts + 1, lastError = ? WHERE id = ?',
      [errorMsg, id],
    );

    final rows = await db.query(
      'sync_queue',
      columns: ['attempts'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );

    final attempts =
        (rows.isNotEmpty ? rows.first['attempts'] as num? : null)?.toInt() ?? 0;

    if (attempts >= maxSyncAttempts) {
      await db.rawUpdate('UPDATE sync_queue SET synced = -1 WHERE id = ?', [
        id,
      ]);
      // ignore: avoid_print
      print('Sync row $id parked after $attempts attempts: $errorMsg');
    }
  }

  /// Un-parks failed rows so they retry. Safe to call — every movement is
  /// deduplicated server-side by clientId, so a re-send cannot double-count.
  static Future<void> recoverFailedTransactions() async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE sync_queue SET synced = 0, attempts = 0 WHERE synced = -1',
    );
  }

  static Future<int> getParkedSyncCount(String branchId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM sync_queue WHERE branchId = ? AND synced = -1',
      [branchId],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  static Future<void> clearSyncedQueue() async {
    final db = await database;
    await db.delete('sync_queue', where: 'synced = ?', whereArgs: [1]);
  }

  static Future<int> getPendingSyncCount(String branchId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM sync_queue WHERE branchId = ? AND synced = 0',
      [branchId],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  // =========================================================================
  // STOCK MOVEMENTS — the heart of the fix
  // =========================================================================

  /// Records a stock movement: writes the ledger row, adjusts local stock by
  /// ADDITION, and queues the movement for the server.
  ///
  /// [delta] is SIGNED:  -2 = two left the shelf,  +5 = five arrived.
  ///
  /// Must be called inside a transaction — pass the txn as [executor].
  static Future<void> recordStockMovement(
    DatabaseExecutor executor, {
    required String barcode,
    required String itemName,
    required String action,
    required int delta,
    String branchId = defaultBranchId,
  }) async {
    if (delta == 0) return;

    final existing = await executor.query(
      'items',
      where: 'barcode = ?',
      whereArgs: [barcode],
      limit: 1,
    );
    if (existing.isEmpty) return;

    final int trackStock = (existing.first['trackStock'] as num?)?.toInt() ?? 1;
    if (trackStock == 0) return; // untracked item — stock is meaningless

    final payload = {
      'clientId': _newClientId('history'), // generated ONCE, reused on retry
      'itemName': itemName,
      'barcode': barcode,
      'action': action,
      'qty': delta.abs(), // keeps existing history screens working
      'delta': delta, // what the server actually applies
      'createdAt': _now(),
    };

    await executor.insert(
      'item_history',
      payload,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    // Local stock also moves by addition, never assignment.
    await executor.rawUpdate(
      'UPDATE items SET quantity = quantity + ? WHERE barcode = ? AND trackStock = 1',
      [delta, barcode],
    );

    await _insertSyncQueue(
      executor,
      entityType: 'history',
      operation: 'insert',
      payload: payload,
      branchId: branchId,
    );
  }

  /// Standalone stock adjustment for callers not already in a transaction.
  static Future<void> adjustStockByDelta({
    required String barcode,
    required String itemName,
    required String action,
    required int delta,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await recordStockMovement(
        txn,
        barcode: barcode,
        itemName: itemName,
        action: action,
        delta: delta,
        branchId: branchId,
      );
    });
  }

  // =========================================================================
  // SALES
  // =========================================================================

  /// Records a sale AND the stock that left the shelf, in one transaction.
  ///
  /// [lines] = [{ 'barcode': '123', 'itemName': 'Coke', 'qty': 2 }, ...]
  ///
  /// The old code recorded the sale but reduced stock through a separate
  /// absolute write, and never wrote a history row — which is why there were
  /// zero 'Sale' rows in a 3,841-row history table.
  static Future<void> insertSaleWithStock({
    required Map<String, dynamic> sale,
    required List<Map<String, dynamic>> lines,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      final String clientId =
          sale['clientId']?.toString().trim().isNotEmpty == true
          ? sale['clientId'].toString()
          : _newClientId('sale');

      final salePayload = {
        'clientId': clientId,
        'type': sale['type'],
        'price': sale['price'],
        'saleDate': sale['saleDate'] ?? _now(),
      };

      await txn.insert(
        'sales',
        salePayload,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      await _insertSyncQueue(
        txn,
        entityType: 'sale',
        operation: 'insert',
        payload: salePayload,
        branchId: branchId,
      );

      for (final line in lines) {
        final int qty = (line['qty'] as num?)?.toInt() ?? 0;
        final String barcode = line['barcode']?.toString() ?? '';
        if (qty <= 0 || barcode.isEmpty) continue;

        await recordStockMovement(
          txn,
          barcode: barcode,
          itemName: line['itemName']?.toString() ?? '',
          action: 'Sale',
          delta: -qty, // negative — stock going out
          branchId: branchId,
        );
      }
    });
  }

  /// Reverses a sale: puts the stock back and records why.
  static Future<void> voidSale({
    required List<Map<String, dynamic>> lines,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final line in lines) {
        final int qty = (line['qty'] as num?)?.toInt() ?? 0;
        final String barcode = line['barcode']?.toString() ?? '';
        if (qty <= 0 || barcode.isEmpty) continue;

        await recordStockMovement(
          txn,
          barcode: barcode,
          itemName: line['itemName']?.toString() ?? '',
          action: 'Return',
          delta: qty, // positive — stock coming back
          branchId: branchId,
        );
      }
    });
  }

  // =========================================================================
  // ITEMS
  // =========================================================================

  /// Creates an item, or adds stock to an existing one.
  ///
  /// `item['quantity']` means "the amount being ADDED", not the new total.
  /// The item sync payload deliberately carries NO quantity — that field is
  /// what used to overwrite the other device's sales.
  static Future<void> insertOrUpdateItem(
    Map<String, dynamic> item, {
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    final String barcode = item['barcode']?.toString().trim() ?? '';
    final String name = item['name']?.toString().trim() ?? '';
    final int incomingQty = (item['quantity'] as num?)?.toInt() ?? 0;
    final double priceUnit = (item['priceUnit'] as num?)?.toDouble() ?? 0.0;
    final int trackStock = (item['trackStock'] as num?)?.toInt() ?? 1;
    final int saleEffect = (item['saleEffect'] as num?)?.toInt() ?? 1;

    if (barcode.isEmpty || name.isEmpty) {
      throw Exception('Barcode and name are required.');
    }

    await db.transaction((txn) async {
      final existing = await txn.query(
        'items',
        where: 'barcode = ?',
        whereArgs: [barcode],
      );

      final bool isNew = existing.isEmpty;

      if (isNew) {
        // Created EMPTY. Stock arrives via the movement below, so there is
        // exactly one route by which stock can enter.
        await txn.insert('items', {
          'barcode': barcode,
          'name': name,
          'quantity': 0,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': saleEffect,
          'isDeleted': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        // Master data only — quantity untouched.
        await txn.update(
          'items',
          {
            'name': name,
            'priceUnit': priceUnit,
            'trackStock': trackStock,
            'saleEffect': saleEffect,
            'isDeleted': 0,
          },
          where: 'barcode = ?',
          whereArgs: [barcode],
        );
      }

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'upsert',
        payload: {
          'barcode': barcode,
          'name': name,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': saleEffect,
          'isDeleted': 0,
        },
        branchId: branchId,
      );

      if (trackStock == 1 && incomingQty != 0) {
        await recordStockMovement(
          txn,
          barcode: barcode,
          itemName: name,
          action: isNew ? 'Added Item' : 'Updated Item',
          delta: incomingQty, // the amount added — already a delta
          branchId: branchId,
        );
      }
    });
  }

  /// Edits an item. `quantity` is the new TOTAL as typed by the user; it is
  /// converted to a delta so a concurrent sale on another device survives.
  ///
  /// [baselineQuantity] is the number the user SAW in the field before
  /// editing. Always pass it. Without it the delta is measured against the
  /// current database value, and if the screen was stale — say it showed 10
  /// while the DB had dropped to 8 — saving an untouched quantity field
  /// would invent +2 of stock out of nothing.
  static Future<void> updateItemOnly({
    required String barcode,
    required String name,
    required int quantity,
    required double priceUnit,
    required int trackStock,
    required int saleEffect,
    int? baselineQuantity,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    if (barcode.trim().isEmpty || name.trim().isEmpty) {
      throw Exception('Barcode and name are required.');
    }

    final String cleanBarcode = barcode.trim();
    final String cleanName = name.trim();

    await db.transaction((txn) async {
      final existing = await txn.query(
        'items',
        where: 'barcode = ?',
        whereArgs: [cleanBarcode],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw Exception('Item not found. Update failed.');
      }

      final int oldQty = (existing.first['quantity'] as num?)?.toInt() ?? 0;

      await txn.update(
        'items',
        {
          'name': cleanName,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': trackStock == 1 ? 1 : saleEffect,
        },
        where: 'barcode = ?',
        whereArgs: [cleanBarcode],
      );

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'edit',
        payload: {
          'barcode': cleanBarcode,
          'name': cleanName,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': trackStock == 1 ? 1 : saleEffect,
        },
        branchId: branchId,
      );

      if (trackStock == 1) {
        // Measured against what the user saw, falling back to the DB value.
        final int baseline = baselineQuantity ?? oldQty;
        final int delta = quantity - baseline; // absolute → delta
        if (delta != 0) {
          await recordStockMovement(
            txn,
            barcode: cleanBarcode,
            itemName: cleanName,
            action: 'Edited Item',
            delta: delta,
            branchId: branchId,
          );
        }
      }
    });
  }

  static Future<void> deleteItem(
    String barcode, {
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'items',
        where: 'barcode = ?',
        whereArgs: [barcode],
        limit: 1,
      );

      if (existing.isNotEmpty) {
        final int currentQty =
            (existing.first['quantity'] as num?)?.toInt() ?? 0;

        // Take the stock out through the ledger first, so the books balance.
        if (currentQty != 0) {
          await recordStockMovement(
            txn,
            barcode: barcode,
            itemName: existing.first['name']?.toString() ?? '',
            action: 'Deleted Item',
            delta: -currentQty,
            branchId: branchId,
          );
        }
      }

      await txn.update(
        'items',
        {'isDeleted': 1},
        where: 'barcode = ?',
        whereArgs: [barcode],
      );

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'delete',
        payload: {'barcode': barcode, 'isDeleted': 1},
        branchId: branchId,
      );
    });
  }

  /// Physical recount. The ONE place an absolute number is legitimate — the
  /// person counted the shelf, so their number beats the computed total.
  /// Keep this rare, and ideally run it on one device at a time.
  static Future<void> applyStockTake({
    required String barcode,
    required String itemName,
    required int countedQty,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    await db.transaction((txn) async {
      final existing = await txn.query(
        'items',
        where: 'barcode = ?',
        whereArgs: [barcode],
        limit: 1,
      );
      if (existing.isEmpty) return;

      final int oldQty = (existing.first['quantity'] as num?)?.toInt() ?? 0;

      await txn.update(
        'items',
        {'quantity': countedQty},
        where: 'barcode = ? AND trackStock = 1',
        whereArgs: [barcode],
      );

      final payload = {
        'clientId': _newClientId('stocktake'),
        'itemName': itemName,
        'barcode': barcode,
        'action': 'Stock Take',
        'qty': countedQty,
        'delta': countedQty - oldQty,
        'countedQty': countedQty,
        'createdAt': _now(),
      };

      await txn.insert(
        'item_history',
        payload,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      await _insertSyncQueue(
        txn,
        entityType: 'stockTake',
        operation: 'set',
        payload: payload,
        branchId: branchId,
      );
    });
  }

  // =========================================================================
  // READS
  // =========================================================================

  static Future<List<Map<String, Object?>>> getItems() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT * FROM items WHERE isDeleted IS NULL OR isDeleted = 0 ORDER BY name ASC',
    );
    // Deep copy so Flutter's state management sees a new object.
    return rows.map((row) => Map<String, Object?>.from(row)).toList();
  }

  static Future<List<Map<String, dynamic>>> getItemsPaginated({
    required int limit,
    required int offset,
  }) async {
    final db = await database;
    final rows = await db.query(
      'items',
      where: 'isDeleted = 0',
      orderBy: 'name ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<Map<String, Object?>?> getItemByBarcode(String barcode) async {
    final db = await database;
    final maps = await db.query(
      'items',
      where: 'barcode = ? AND isDeleted = 0',
      whereArgs: [barcode],
    );
    return maps.isNotEmpty ? maps.first : null;
  }

  static Future<List<Map<String, dynamic>>> getAllItemHistory() async {
    final db = await database;
    final rows = await db.query('item_history', orderBy: 'createdAt DESC');
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<List<Map<String, dynamic>>> getItemHistoryPaginated({
    required int limit,
    required int offset,
  }) async {
    final db = await database;
    final rows = await db.query(
      'item_history',
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<List<Map<String, dynamic>>> getSalesPaginated({
    required int limit,
    required int offset,
    String? saleDate,
  }) async {
    final db = await database;

    final rows = await db.query(
      'sales',
      where: saleDate == null ? null : "${ShopTime.sqlLocalDate} = ?",
      whereArgs: saleDate == null ? null : [saleDate],
      orderBy: 'saleDate DESC',
      limit: limit,
      offset: offset,
    );

    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<List<Map<String, dynamic>>> getSaleDateSummariesPaginated({
    required int limit,
    required int offset,
  }) async {
    final db = await database;

    final rows = await db.rawQuery(
      '''
    SELECT
      ${ShopTime.sqlLocalDate} AS dateKey,
      COUNT(*) AS transactionCount,
      COALESCE(SUM(COALESCE(price, 0)), 0) AS totalAmount
    FROM sales
    WHERE saleDate IS NOT NULL AND length(saleDate) >= 10
    GROUP BY dateKey
    ORDER BY dateKey DESC
    LIMIT ? OFFSET ?
    ''',
      [limit, offset],
    );

    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<Map<String, dynamic>?> getSaleDateSummary(
    String saleDate,
  ) async {
    final db = await database;

    final rows = await db.rawQuery(
      '''
    SELECT
      ${ShopTime.sqlLocalDate} AS dateKey,
      COUNT(*) AS transactionCount,
      COALESCE(SUM(COALESCE(price, 0)), 0) AS totalAmount
    FROM sales
    WHERE ${ShopTime.sqlLocalDate} = ?
    GROUP BY dateKey
    ''',
      [saleDate],
    );

    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }
 
static Future<List<Map<String, dynamic>>> getSalesByDate(String saleDate) async {
  final db = await database;
 
  final rows = await db.query(
    'sales',
    where: "${ShopTime.sqlLocalDate} = ?",
    whereArgs: [saleDate],
    orderBy: 'saleDate DESC',
  );
 
  return rows.map((e) => Map<String, dynamic>.from(e)).toList();
}
 

  static Future<List<Map<String, Object?>>> getSales() async {
    final db = await database;
    return db.query('sales', orderBy: 'saleDate DESC');
  }

  static Future<void> deleteSale(int id) async {
    final db = await database;
    await db.delete('sales', where: 'id = ?', whereArgs: [id]);
  }

  // =========================================================================
  // PULLING FROM SERVER
  //
  // These overwrite local data with the server's, which is CORRECT now — the
  // server is the only party that has seen every device's movements.
  //
  // But only pull AFTER a successful push, or the server's totals (which
  // don't yet include this device's pending sales) will look wrong.
  // =========================================================================

  static Future<void> upsertItemFromServer(Map<String, dynamic> item) async {
    final db = await database;

    final String barcode = item['barcode']?.toString().trim() ?? '';
    if (barcode.isEmpty) return;

    final int serverQty =
        (item['quantity'] as num?)?.toInt() ??
        int.tryParse(item['quantity']?.toString() ?? '0') ??
        0;

    int isDeleted = 0;
    final rawIsDeleted = item['isDeleted'];
    if (rawIsDeleted != null) {
      final strVal = rawIsDeleted.toString().toLowerCase();
      if (strVal == '1' || strVal == 'true') isDeleted = 1;
    }

    final data = {
      'barcode': barcode,
      'name': item['name']?.toString() ?? '',
      'quantity': serverQty,
      'priceUnit': double.tryParse(item['priceUnit']?.toString() ?? '0') ?? 0.0,
      'trackStock': (item['trackStock'] as num?)?.toInt() ?? 1,
      'saleEffect': (item['saleEffect'] as num?)?.toInt() ?? 1,
      'isDeleted': isDeleted,
    };

    final existing = await db.query(
      'items',
      where: 'barcode = ?',
      whereArgs: [barcode],
    );

    if (existing.isNotEmpty) {
      await db.update(
        'items',
        data,
        where: 'barcode = ?',
        whereArgs: [barcode],
      );
    } else {
      await db.insert('items', data);
    }
  }

  /// Applies the authoritative item list returned by the sync response.
  static Future<void> applyServerItems(List<dynamic> items) async {
    for (final item in items) {
      await upsertItemFromServer(Map<String, dynamic>.from(item as Map));
    }
  }

  static Future<void> upsertHistoryFromServer(Map<String, dynamic> h) async {
    final db = await database;

    final int? serverId = int.tryParse(
      (h['id'] ?? h['serverId'] ?? '').toString(),
    );
    final String clientId = h['clientId']?.toString().trim() ?? '';

    final String itemName = h['itemName']?.toString() ?? '';
    final String barcode = h['barcode']?.toString() ?? '';
    final String action = h['action']?.toString() ?? '';
    final int qty = (h['qty'] as num?)?.toInt() ?? 0;
    final int delta =
        (h['delta'] as num?)?.toInt() ??
        int.tryParse(h['delta']?.toString() ?? '') ??
        0;
    final String createdAt = h['createdAt']?.toString() ?? '';

    final data = {
      'serverId': serverId,
      'clientId': clientId.isEmpty ? null : clientId,
      'itemName': itemName,
      'barcode': barcode,
      'action': action,
      'qty': qty,
      'delta': delta,
      'createdAt': createdAt,
    };

    if (clientId.isNotEmpty) {
      final existing = await db.query(
        'item_history',
        where: 'clientId = ?',
        whereArgs: [clientId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await db.update(
          'item_history',
          data,
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        return;
      }
    }

    final existingLocal = await db.query(
      'item_history',
      where: '''
        serverId IS NULL AND itemName = ? AND barcode = ?
        AND action = ? AND qty = ? AND createdAt = ?
      ''',
      whereArgs: [itemName, barcode, action, qty, createdAt],
      limit: 1,
    );

    if (existingLocal.isNotEmpty) {
      await db.update(
        'item_history',
        data,
        where: 'id = ?',
        whereArgs: [existingLocal.first['id']],
      );
      return;
    }

    await db.insert(
      'item_history',
      data,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> upsertSaleFromServer(Map<String, dynamic> sale) async {
    final db = await database;

    final int? serverId = int.tryParse(
      (sale['id'] ?? sale['serverId'] ?? '').toString(),
    );
    final String clientId = sale['clientId']?.toString().trim() ?? '';

    final data = {
      'serverId': serverId,
      'clientId': clientId.isEmpty ? null : clientId,
      'type': sale['type']?.toString() ?? '',
      'price': double.tryParse(sale['price']?.toString() ?? '0') ?? 0.0,
      'saleDate': sale['saleDate']?.toString() ?? '',
    };

    if (clientId.isNotEmpty) {
      final existing = await db.query(
        'sales',
        where: 'clientId = ?',
        whereArgs: [clientId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        await db.update(
          'sales',
          data,
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        return;
      }
    }

    await db.insert('sales', data, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // =========================================================================
  // HOUSEKEEPING
  // =========================================================================

  static Future<void> closeDb() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  static Future<void> clearLocalData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('items');
      await txn.delete('sales');
      await txn.delete('item_history');
      await txn.delete('sync_queue');
      // app_meta is intentionally NOT cleared — the device keeps its id.
    });
  }
}
