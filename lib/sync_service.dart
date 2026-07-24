import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'db_helper.dart';
import 'dart:io';
import 'dart:async';

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

  Future<bool> synchronize({required String branchId}) async {
    final pushed = await syncPending(branchId: branchId);

    if (!pushed) return false;

    final pulled = await pullFromServer(branchId: branchId);

    return pulled;
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
            .timeout(const Duration(seconds: 60)); // ← shorter timeout
        debugPrint('>>> items status: ${itemsRes.statusCode}');
      } catch (e) {
        debugPrint('>>> items request failed: $e');
        itemsRes = http.Response('{}', 500);
      }

      if (itemsRes.statusCode == 200) {
        final body = jsonDecode(itemsRes.body);
        if (body['success'] == true) {
          final List items = body['data'] as List? ?? [];
          debugPrint('>>> items count: ${items.length}');
          
          // 1. Gather all barcodes the server ACTUALLY sent us
          final Set<String> serverBarcodes = {};
          
          for (final item in items) {
            final barcode = item['barcode']?.toString() ?? '';
            if (barcode.isNotEmpty) {
               serverBarcodes.add(barcode);
            }
            
            await DBHelper.upsertItemFromServer(
              Map<String, dynamic>.from(item),
            );
          }

          final Set<String> pendingBarcodes = {};
          final pendingQueue = await DBHelper.getPendingSyncQueue(branchId);
          for (final row in pendingQueue) {
            if (row['entityType'] == 'item') {
              try {
                final payloadText = row['payload']?.toString() ?? '{}';
                final payload = jsonDecode(payloadText) as Map<String, dynamic>;
                final barcode = payload['barcode']?.toString() ?? '';
                if (barcode.isNotEmpty) {
                  pendingBarcodes.add(barcode);
                }
              } catch (_) {}
            }
          }

              // 3. HARD DELETE missing local items
          final localItems = await DBHelper.getItems();
          
          final db = await DBHelper.database; 
          
          for (final localItem in localItems) {
            final localBarcode = localItem['barcode']?.toString() ?? '';
            
            if (localBarcode.isNotEmpty && 
                !serverBarcodes.contains(localBarcode) && 
                !pendingBarcodes.contains(localBarcode)) {
                  
              // Silently hard-delete it locally
              await db.delete(
                'items', 
                where: 'barcode = ?', 
                whereArgs: [localBarcode],
              );
              debugPrint('>>> Hard deleted local item because server dropped it: $localBarcode');
            }
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
            .timeout(const Duration(seconds: 60));
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
            .timeout(const Duration(seconds: 60));
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
    // FIX: Wait briefly if a background sync (via connectivity listener) is already running
    if (_isSyncing) {
      int retries = 0;
      while (_isSyncing && retries < 15) {
        await Future.delayed(const Duration(seconds: 1));
        retries++;
      }
      if (_isSyncing) return false;
    }
    _isSyncing = true;

    try {
      while (true) {
        final allPending = await DBHelper.getPendingSyncQueue(branchId);

        if (allPending.isEmpty) {
          _isSyncing = false;
          return true;
        }

        final pending = allPending.take(15).toList();

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

          Map<String, dynamic> payload = {};
          try {
            payload = jsonDecode(payloadText) as Map<String, dynamic>;
          } catch (e) {
            debugPrint('Invalid JSON payload for ID $id: $e');
            await DBHelper.markQueueError(id, "Invalid JSON payload");
            continue;
          }

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
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: jsonEncode({
                'deviceId': 'flutter-device-$branchId',
                'items': upsertItems,
                'editItems': editItems,
                'deleteItems': deleteItemBarcodes,
                'sales': sales,
                'history': history,
              }),
            )
            .timeout(const Duration(seconds: 120));

        debugPrint('SYNC response: ${response.statusCode} ${response.body}');

        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            final body = jsonDecode(response.body);
            if (body['success'] == true) {
              await DBHelper.markQueueSynced(ids);
              continue;
            } else {
              debugPrint('Batch failed. Falling back to individual sync...');
              await _syncIndividually(pending, branchId);
              continue;
            }
          } catch (e) {
            debugPrint('Sync failed: Expected JSON, got HTML. $e');
            // FIX: If the server returns an HTML error page, fall back to individual sync
            await _syncIndividually(pending, branchId);
            continue;
          }
        } else {
          // FIX: Do not abort on 500 Server Errors! Fall back to isolate the bad row.
          debugPrint(
            'Batch HTTP ${response.statusCode}. Falling back to individual sync...',
          );
          await _syncIndividually(pending, branchId);
          continue;
        }
      }
    } on TimeoutException catch (e) {
      debugPrint('Sync timeout: $e');
      _isSyncing = false;
      return false;
    } on SocketException catch (e) {
      debugPrint('Sync network error (Offline): $e');
      _isSyncing = false;
      return false;
    } catch (e) {
      debugPrint('SyncService critical error: $e');
      _isSyncing = false;
      return false;
    }
  }

  Future<void> _syncIndividually(
    List<Map<String, dynamic>> pendingRows,
    String branchId,
  ) async {
    for (final row in pendingRows) {
      final id = row['id'] as int;
      final entityType = row['entityType']?.toString() ?? '';
      final operation = row['operation']?.toString() ?? '';

      Map<String, dynamic> payload = {};
      try {
        payload = jsonDecode(row['payload']?.toString() ?? '{}');
      } catch (e) {
        // FIX: Mark queue error so bad JSON doesn't cause an infinite loop
        await DBHelper.markQueueError(id, "Invalid JSON payload");
        continue;
      }

      Map<String, dynamic> requestBody = {
        'deviceId': 'flutter-device-$branchId',
        'items': [],
        'editItems': [],
        'deleteItems': [],
        'sales': [],
        'history': [],
      };

      if (entityType == 'item') {
        if (operation == 'delete')
          requestBody['deleteItems'] = [payload['barcode']?.toString() ?? ''];
        else if (operation == 'edit')
          requestBody['editItems'] = [payload];
        else
          requestBody['items'] = [payload];
      } else if (entityType == 'sale') {
        requestBody['sales'] = [payload];
      } else if (entityType == 'history') {
        requestBody['history'] = [payload];
      }
      try {
        final uri = Uri.parse('$baseUrl/api/$branchId/sync');
        final response = await http
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: jsonEncode(requestBody),
            )
            .timeout(const Duration(seconds: 15));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = jsonDecode(response.body);
          if (body['success'] == true) {
            await DBHelper.markQueueSynced([id]);
          } else {
            await DBHelper.markQueueError(id, body['error'].toString());
          }
        } else {
          debugPrint(
            'Server rejected transaction $id. Status: ${response.statusCode}',
          );
          throw Exception(
            'Server error ${response.statusCode}. Aborting to protect data.',
          );
        }
      } catch (e) {
        debugPrint('Network error on individual sync for ID $id: $e');

        break;
      }
    }
  }
}
