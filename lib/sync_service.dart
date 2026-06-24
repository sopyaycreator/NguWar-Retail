import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db_helper.dart';

class SyncService {
  static const String baseUrl = 'http://z312050-6w40u2.ps11.zwhhosting.com';
  static const String apiKey = 'nguwar-pos-my-secret-2026';

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _isSyncing = false;

  void startListening({required String branchId}) {
    _subscription = Connectivity().onConnectivityChanged.listen((_) async {
      await syncPending(branchId: branchId);
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  Future<bool> pullFromServer({required String branchId}) async {
    try {
      debugPrint('>>> pullFromServer start: $branchId');

      // Pull items
      final itemsUri = Uri.parse('$baseUrl/api/$branchId/items');
      debugPrint('>>> GET $itemsUri');

      http.Response itemsRes;
      try {
        itemsRes = await http
            .get(itemsUri, headers: {'x-api-key': apiKey})
            .timeout(const Duration(seconds: 10)); // ← shorter timeout
        debugPrint('>>> items status: ${itemsRes.statusCode}');
        debugPrint('>>> items body: ${itemsRes.body}');
      } catch (e) {
        debugPrint('>>> items request failed: $e');
        itemsRes = http.Response('{}', 500);
      }

      if (itemsRes.statusCode == 200) {
        final body = jsonDecode(itemsRes.body);
        if (body['success'] == true) {
          final List items = body['data'] as List? ?? [];
          debugPrint('>>> items count: ${items.length}');
          for (final item in items) {
            await DBHelper.upsertItemFromServer(
              Map<String, dynamic>.from(item),
            );
          }
        }
      }

      // Pull sales
      final salesUri = Uri.parse('$baseUrl/api/$branchId/sales');
      debugPrint('>>> GET $salesUri');

      http.Response salesRes;
      try {
        salesRes = await http
            .get(salesUri, headers: {'x-api-key': apiKey})
            .timeout(const Duration(seconds: 10));
        debugPrint('>>> sales status: ${salesRes.statusCode}');
      } catch (e) {
        debugPrint('>>> sales request failed: $e');
        salesRes = http.Response('{}', 500);
      }

      if (salesRes.statusCode == 200) {
        final body = jsonDecode(salesRes.body);
        if (body['success'] == true) {
          final List sales = body['data'] as List? ?? [];
          debugPrint('>>> sales count: ${sales.length}');
          for (final sale in sales) {
            await DBHelper.upsertSaleFromServer(
              Map<String, dynamic>.from(sale),
            );
          }
        }
      }
      // Pull item history
      final historyUri = Uri.parse('$baseUrl/api/$branchId/history');
      debugPrint('>>> GET $historyUri');

      http.Response historyRes;
      try {
        historyRes = await http
            .get(historyUri, headers: {'x-api-key': apiKey})
            .timeout(const Duration(seconds: 10));
        debugPrint('>>> history status: ${historyRes.statusCode}');
      } catch (e) {
        debugPrint('>>> history request failed: $e');
        historyRes = http.Response('{}', 500);
      }

      if (historyRes.statusCode == 200) {
        final body = jsonDecode(historyRes.body);
        if (body['success'] == true) {
          final List history = body['data'] as List? ?? [];
          debugPrint('>>> history count: ${history.length}');
          for (final h in history) {
            await DBHelper.upsertHistoryFromServer(
              Map<String, dynamic>.from(h),
            );
          }
        }
      }

      debugPrint('>>> pullFromServer done');
      return true;
    } catch (e) {
      debugPrint('pullFromServer error: $e');
      return false;
    }
  }

   Future<bool> syncPending({required String branchId}) async {
    if (_isSyncing) return false;
    _isSyncing = true;

    try {
      final allPending = await DBHelper.getPendingSyncQueue(branchId);
      if (allPending.isEmpty) {
        _isSyncing = false;
        return true;
      }

     
      final pending = allPending.take(50).toList();

      final List<int> ids = [];
      final List<Map<String, dynamic>> upsertItems = [];
      final List<Map<String, dynamic>> editItems = [];
      final List<String> deleteItemBarcodes = [];
      final List<Map<String, dynamic>> sales = [];
      final List<Map<String, dynamic>> history = [];

      for (final row in pending) {
        final id = row['id'] as int;
        final entityType = row['entityType']?.toString() ?? '';
        final operation = row['operation']?.toString() ?? '';
        final payloadText = row['payload']?.toString() ?? '{}';
        final payload = jsonDecode(payloadText) as Map<String, dynamic>;

        ids.add(id);

        if (entityType == 'item') {
          if (operation == 'delete') {
            deleteItemBarcodes.add(payload['barcode']?.toString() ?? '');
          } else if (operation == 'edit') {
            editItems.add(payload);
          } else {
            upsertItems.add(payload);
          }
        } else if (entityType == 'sale') {
          sales.add(payload);
        } else if (entityType == 'history') {
          history.add(payload);
        }
      }

      final uri = Uri.parse('$baseUrl/api/$branchId/sync');

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json', 'x-api-key': apiKey},
            body: jsonEncode({
              'deviceId': 'flutter-device-$branchId',
              'items': upsertItems,
              'editItems': editItems,
              'deleteItems': deleteItemBarcodes,
              'sales': sales,
              'history': history,
            }),
          )
          .timeout(const Duration(seconds: 60));

      debugPrint('SYNC response: ${response.statusCode} ${response.body}');

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body);
        if (body['success'] == true) {
          await DBHelper.markQueueSynced(ids);
          _isSyncing = false;

          // ✅ If there are more pending items, sync again automatically
          if (allPending.length > 50) {
            return syncPending(branchId: branchId);
          }

          return true;
        }
      }

      _isSyncing = false;
      return false;
    } catch (e) {
      debugPrint('SyncService error: $e');
      _isSyncing = false;
      return false;
    }
  }
}
