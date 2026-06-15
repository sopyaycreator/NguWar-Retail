import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DBHelper {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;

    _db = await openDatabase(
      join(await getDatabasesPath(), 'pos_inventory.db'),
      version: 4,
      onCreate: (db, version) async {
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
            type TEXT,
            price REAL,
            saleDate TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE item_history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            itemName TEXT,
            barcode TEXT,
            action TEXT,
            qty INTEGER,
            createdAt TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
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
      },
    );

    return _db!;
  }

  static Future<void> insertOrUpdateItem(Map<String, dynamic> item) async {
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
      final List<Map<String, Object?>> existing = await txn.query(
        'items',
        where: 'barcode = ?',
        whereArgs: [barcode],
      );

      String action = 'Added Item';
      int historyQty = trackStock == 1 ? incomingQty : 0;

      if (existing.isNotEmpty) {
        final Map<String, Object?> oldItem = existing.first;
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
        await txn.insert(
          'items',
          {
            'barcode': barcode,
            'name': name,
            'quantity': trackStock == 1 ? incomingQty : 0,
            'priceUnit': priceUnit,
            'trackStock': trackStock,
            'saleEffect': saleEffect,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        action = 'Added Item';
        historyQty = incomingQty;
      }

      await txn.insert('item_history', {
        'itemName': name,
        'barcode': barcode,
        'action': action,
        'qty': historyQty,
        'createdAt': DateTime.now().toIso8601String(),
      });
    });
  }

  static Future<List<Map<String, Object?>>> getItems() async {
    final db = await database;
    return db.query('items', orderBy: 'name ASC');
  }

  static Future<Map<String, Object?>?> getItemByBarcode(String barcode) async {
    final db = await database;
    final List<Map<String, Object?>> maps = await db.query(
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
  }) async {
    final db = await database;
    await db.insert('item_history', {
      'itemName': itemName,
      'barcode': barcode,
      'action': action,
      'qty': qty,
      'createdAt': DateTime.now().toIso8601String(),
    });
  }

 
  static Future<List<Map<String, dynamic>>> getAllItemHistory() async {
  final db = await database;
  return await db.query(
    'item_history',
    orderBy: 'createdAt DESC',
  );
}

  static Future<void> updateItemQuantity(String barcode, int newQty) async {
    final db = await database;

    final item = await getItemByBarcode(barcode);
    if (item == null) return;

    final int trackStock = (item['trackStock'] as num?)?.toInt() ?? 1;
    if (trackStock == 0) return;

    await db.update(
      'items',
      {'quantity': newQty < 0 ? 0 : newQty},
      where: 'barcode = ?',
      whereArgs: [barcode],
    );
  }

  static Future<void> deleteItem(String barcode) async {
    final db = await database;
    await db.delete('items', where: 'barcode = ?', whereArgs: [barcode]);
  }

  static Future<void> insertSale(Map<String, dynamic> sale) async {
    final db = await database;
    await db.insert('sales', sale);
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
}