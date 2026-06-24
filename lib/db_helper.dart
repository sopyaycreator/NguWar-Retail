import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DBHelper {
  static Database? _db;

  static const int _dbVersion = 7;
  static const String defaultBranchId = 'nguwar_1';

  static Future<Database> get database async {
    if (_db != null) return _db!;

    _db = await openDatabase(
      join(await getDatabasesPath(), 'pos_inventory.db'),
      version: _dbVersion,
      onCreate: (db, version) async {
        await _createTables(db);
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
        saleEffect INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE sales(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serverId INTEGER UNIQUE,
        type TEXT,
        price REAL,
        saleDate TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE item_history(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serverId INTEGER UNIQUE,
        itemName TEXT,
        barcode TEXT,
        action TEXT,
        qty INTEGER,
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
        synced INTEGER DEFAULT 0
      )
    ''');
  }

  static Future<void> _ensureItemColumns(Database db) async {
    final columns = await db.rawQuery("PRAGMA table_info(items)");
    final hasTrackStock = columns.any((col) => col['name'] == 'trackStock');
    final hasSaleEffect = columns.any((col) => col['name'] == 'saleEffect');

    if (!hasTrackStock) {
      await db.execute(
        'ALTER TABLE items ADD COLUMN trackStock INTEGER DEFAULT 1',
      );
    }

    if (!hasSaleEffect) {
      await db.execute(
        'ALTER TABLE items ADD COLUMN saleEffect INTEGER DEFAULT 1',
      );
    }
  }

  static String _now() => DateTime.now().toIso8601String();

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
      orderBy: 'createdAt ASC',
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

      String action = 'Added Item';
      int historyQty = trackStock == 1 ? incomingQty : 0;

      if (existing.isNotEmpty) {
        final oldItem = existing.first;
        final int currentQty = (oldItem['quantity'] as num?)?.toInt() ?? 0;

        final int updatedQty = trackStock == 1 ? currentQty + incomingQty : 0;

        await txn.update(
          'items',
          {
            'name': name,
            'quantity': updatedQty,
            'priceUnit': priceUnit,
            'trackStock': trackStock,
            'saleEffect': saleEffect,
          },
          where: 'barcode = ?',
          whereArgs: [barcode],
        );

        action = 'Updated Item';
        historyQty = incomingQty;
      } else {
        await txn.insert('items', {
          'barcode': barcode,
          'name': name,
          'quantity': trackStock == 1 ? incomingQty : 0,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': saleEffect,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        action = 'Added Item';
        historyQty = incomingQty;
      }

      final historyPayload = {
        'itemName': name,
        'barcode': barcode,
        'action': action,
        'qty': historyQty,
        'createdAt': _now(),
      };

      await txn.insert('item_history', historyPayload);

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'upsert',
        payload: {
          'barcode': barcode,
          'name': name,
          'quantity': incomingQty,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': saleEffect,
        },
        branchId: branchId,
      );

      await _insertSyncQueue(
        txn,
        entityType: 'history',
        operation: 'insert',
        payload: historyPayload,
        branchId: branchId,
      );
    });
  }

  static Future<List<Map<String, Object?>>> getItems() async {
    final db = await database;
    return db.query('items', orderBy: 'name ASC');
  }

  static Future<Map<String, Object?>?> getItemByBarcode(String barcode) async {
    final db = await database;
    final maps = await db.query(
      'items',
      where: 'barcode = ?',
      whereArgs: [barcode],
    );

    if (maps.isNotEmpty) return maps.first;
    return null;
  }

  static Future<void> insertItemHistory({
    required String itemName,
    required String barcode,
    required String action,
    required int qty,
    String branchId = defaultBranchId,
    bool enqueue = true,
  }) async {
    final db = await database;

    final payload = {
      'itemName': itemName,
      'barcode': barcode,
      'action': action,
      'qty': qty,
      'createdAt': _now(),
    };

    await db.insert('item_history', payload);

    if (enqueue) {
      await _insertSyncQueue(
        db,
        entityType: 'history',
        operation: 'insert',
        payload: payload,
        branchId: branchId,
      );
    }
  }

  static Future<List<Map<String, dynamic>>> getAllItemHistory() async {
    final db = await database;
    final rows = await db.query('item_history', orderBy: 'createdAt DESC');
    return rows.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<void> updateItemQuantity(
    String barcode,
    int newQty, {
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    final item = await getItemByBarcode(barcode);
    if (item == null) return;

    final int trackStock = (item['trackStock'] as num?)?.toInt() ?? 1;
    if (trackStock == 0) return;

    await db.update(
      'items',
      {'quantity': newQty},
      where: 'barcode = ?',
      whereArgs: [barcode],
    );

    // FIXED: Send the COMPLETE item payload to the sync queue!
    await _insertSyncQueue(
      db,
      entityType: 'item',
      operation: 'quantity_update',
      payload: {
        'barcode': barcode,
        'name': item['name']?.toString() ?? '',
        'quantity': newQty,
        'priceUnit': (item['priceUnit'] as num?)?.toDouble() ?? 0.0,
        'trackStock': trackStock,
        'saleEffect': (item['saleEffect'] as num?)?.toInt() ?? 1,
      },
      branchId: branchId,
    );
  }

  static Future<void> updateItemOnly({
    required String barcode,
    required String name,
    required int quantity,
    required double priceUnit,
    required int trackStock,
    required int saleEffect,
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    if (barcode.trim().isEmpty || name.trim().isEmpty) {
      throw Exception('Barcode and name are required.');
    }

    final String cleanBarcode = barcode.trim();
    final String cleanName = name.trim();

    await db.transaction((txn) async {
      final updatedRows = await txn.update(
        'items',
        {
          'name': cleanName,
          'quantity': trackStock == 1 ? quantity : 0,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': trackStock == 1 ? 1 : saleEffect,
        },
        where: 'barcode = ?',
        whereArgs: [cleanBarcode],
      );

      if (updatedRows == 0) {
        throw Exception('Item not found. Update failed.');
      }

      final historyPayload = {
        'itemName': cleanName,
        'barcode': cleanBarcode,
        'action': 'Edited Item',
        'qty': trackStock == 1 ? quantity : 0,
        'createdAt': _now(),
      };

      await txn.insert('item_history', historyPayload);

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'edit',
        payload: {
          'barcode': cleanBarcode,
          'name': cleanName,
          'quantity': trackStock == 1 ? quantity : 0,
          'priceUnit': priceUnit,
          'trackStock': trackStock,
          'saleEffect': trackStock == 1 ? 1 : saleEffect,
        },
        branchId: branchId,
      );

      await _insertSyncQueue(
        txn,
        entityType: 'history',
        operation: 'insert',
        payload: historyPayload,
        branchId: branchId,
      );
    });
  }

  static Future<void> deleteItem(
    String barcode, {
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    final existing = await getItemByBarcode(barcode);

    await db.transaction((txn) async {
      await txn.delete('items', where: 'barcode = ?', whereArgs: [barcode]);

      await _insertSyncQueue(
        txn,
        entityType: 'item',
        operation: 'delete',
        payload: {'barcode': barcode},
        branchId: branchId,
      );

      if (existing != null) {
        final historyPayload = {
          'itemName': existing['name']?.toString() ?? '',
          'barcode': barcode,
          'action': 'Deleted Item',
          'qty': (existing['quantity'] as num?)?.toInt() ?? 0,
          'createdAt': _now(),
        };

        await txn.insert('item_history', historyPayload);

        await _insertSyncQueue(
          txn,
          entityType: 'history',
          operation: 'insert',
          payload: historyPayload,
          branchId: branchId,
        );
      }
    });
  }

  static Future<void> insertSale(
    Map<String, dynamic> sale, {
    String branchId = defaultBranchId,
  }) async {
    final db = await database;

    final payload = {
      'type': sale['type'],
      'price': sale['price'],
      'saleDate': sale['saleDate'] ?? _now(),
    };

    await db.insert('sales', payload);

    await _insertSyncQueue(
      db,
      entityType: 'sale',
      operation: 'insert',
      payload: payload,
      branchId: branchId,
    );
  }

  // Upsert item from server (no sync queue — data already on server)
  static Future<void> upsertItemFromServer(Map<String, dynamic> item) async {
    final db = await database;
    final String barcode = item['barcode']?.toString() ?? '';
    final existing = await getItemByBarcode(barcode);

    if (existing != null) {
      // ✅ Item already exists locally — only update name/price/settings
      // NEVER overwrite quantity from server (local is more accurate)
      await db.update(
        'items',
        {
          'name': item['name']?.toString() ?? '',
          'priceUnit':
              double.tryParse(item['priceUnit']?.toString() ?? '0') ?? 0.0,
          'trackStock': (item['trackStock'] as num?)?.toInt() ?? 1,
          'saleEffect': (item['saleEffect'] as num?)?.toInt() ?? 1,
        },
        where: 'barcode = ?',
        whereArgs: [barcode],
      );
    } else {
      // ✅ New item — insert everything including quantity
      await db.insert('items', {
        'barcode': barcode,
        'name': item['name']?.toString() ?? '',
        'quantity': (item['quantity'] as num?)?.toInt() ?? 0,
        'priceUnit':
            double.tryParse(item['priceUnit']?.toString() ?? '0') ?? 0.0,
        'trackStock': (item['trackStock'] as num?)?.toInt() ?? 1,
        'saleEffect': (item['saleEffect'] as num?)?.toInt() ?? 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> upsertHistoryFromServer(Map<String, dynamic> h) async {
    final db = await database;
    await db.insert('item_history', {
      'serverId':  h['id'], 
      'itemName': h['itemName']?.toString() ?? '',
      'barcode': h['barcode']?.toString() ?? '',
      'action': h['action']?.toString() ?? '',
      'qty': (h['qty'] as num?)?.toInt() ?? 0,
      'createdAt': h['createdAt']?.toString() ?? '',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  // Upsert sale from server (no sync queue — data already on server)
  static Future<void> upsertSaleFromServer(Map<String, dynamic> sale) async {
    final db = await database;
    await db.insert(
      'sales',
      {
        'serverId': sale['id'],
        'type': sale['type']?.toString() ?? '',
        'price': double.tryParse(sale['price']?.toString() ?? '0') ?? 0.0,
        'saleDate': sale['saleDate']?.toString() ?? '',
      },
      conflictAlgorithm:
          ConflictAlgorithm.ignore, // don't duplicate existing sales
    );
  }

  static Future<List<Map<String, Object?>>> getSales() async {
    final db = await database;
    return db.query('sales', orderBy: 'saleDate DESC');
  }

  static Future<void> deleteSale(int id) async {
    final db = await database;
    await db.delete('sales', where: 'id = ?', whereArgs: [id]);
  }

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
    });
  }
}
