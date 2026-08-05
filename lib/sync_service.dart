import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db_helper.dart';

class SyncService {
  static const String baseUrl = 'https://z312050-6w40u2.ps11.zwhhosting.com';
  static const String apiKey = 'nguwar-pos-my-secret-2026';

  /// Tells the server this device speaks the delta protocol. The server
  /// falls back to the old absolute behaviour for anything without it, so a
  /// half-updated fleet keeps working during rollout.
  static const int syncVersion = 2;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  Timer? _connectivityDebounce;
  bool _isSyncing = false;

  void startListening({required String branchId}) {
    _subscription?.cancel();

    _subscription = Connectivity().onConnectivityChanged.listen((_) {
      _connectivityDebounce?.cancel();
      _connectivityDebounce = Timer(const Duration(seconds: 3), () async {
        if (!_isSyncing) {
          await synchronize(branchId: branchId);
        }
      });
    });
  }

  Future<void> dispose() async {
    _connectivityDebounce?.cancel();
    await _subscription?.cancel();
  }

  /// PUSH first, THEN pull. This order is mandatory.
  ///
  /// Pulling first would overwrite local stock with the server's totals,
  /// which don't yet include this device's pending sales — the numbers would
  /// look wrong until the next push.
  Future<bool> synchronize({required String branchId}) async {
    final pushed = await syncPending(branchId: branchId);
    if (!pushed) return false;
    return await pullFromServer(branchId: branchId);
  }

  // =========================================================================
  // PUSH
  // =========================================================================

  Future<bool> syncPending({required String branchId}) async {
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
      final deviceId = await DBHelper.getDeviceId();

      // Hard stop. The old code had `while (true)` with no exit when a batch
      // kept failing: markQueueError only printed, the row stayed pending,
      // the same batch was re-fetched, forever. This bounds it.
      int loopGuard = 0;
      const int maxLoops = 200;

      while (true) {
        if (++loopGuard > maxLoops) {
          debugPrint('SYNC: loop guard hit — stopping, will resume next cycle');
          return false;
        }

        final allPending = await DBHelper.getPendingSyncQueue(branchId);
        if (allPending.isEmpty) return true;

        final int batchSize =
            allPending.length > 100 ? 5 : (allPending.length > 50 ? 10 : 15);
        final pending = allPending.take(batchSize).toList();

        final List<int> ids = [];
        final List<Map<String, dynamic>> upsertItems = [];
        final List<Map<String, dynamic>> editItems = [];
        final List<String> deleteItemBarcodes = [];
        final List<Map<String, dynamic>> sales = [];
        final List<Map<String, dynamic>> history = [];
        final List<Map<String, dynamic>> stockTake = [];

        for (final row in pending) {
          final id = row['id'] as int;
          final entityType = row['entityType']?.toString() ?? '';
          final operation = row['operation']?.toString() ?? '';

          Map<String, dynamic> payload;
          try {
            payload = jsonDecode(row['payload']?.toString() ?? '{}')
                as Map<String, dynamic>;
          } catch (e) {
            debugPrint('Invalid JSON payload for ID $id: $e');
            await DBHelper.markQueueError(id, 'Invalid JSON payload');
            continue;
          }

          ids.add(id);

          switch (entityType) {
            case 'item':
              if (operation == 'delete') {
                deleteItemBarcodes.add(payload['barcode']?.toString() ?? '');
              } else if (operation == 'edit') {
                editItems.add(payload);
              } else {
                upsertItems.add(payload);
              }
              break;
            case 'sale':
              sales.add(payload);
              break;
            case 'history':
              history.add(payload);
              break;
            case 'stockTake':
              stockTake.add(payload);
              break;
          }
        }

        if (ids.isEmpty) {
          // Every row in this batch was unparseable and has been counted
          // against its attempt limit. Loop again; they will park out.
          continue;
        }

        final uri = Uri.parse('$baseUrl/api/$branchId/sync');

        http.Response response;
        try {
          response = await http
              .post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-api-key': apiKey,
                },
                body: jsonEncode({
                  'syncVersion': syncVersion,
                  'deviceId': deviceId,
                  'items': upsertItems,
                  'editItems': editItems,
                  'deleteItems': deleteItemBarcodes,
                  'sales': sales,
                  'history': history,
                  'stockTake': stockTake,
                }),
              )
              .timeout(const Duration(seconds: 120));
        } on TimeoutException catch (e) {
          // A timeout often means the server DID commit — our 120s cutoff is
          // shorter than its 180s. Re-sending is safe: every movement carries
          // a clientId, so the server skips ones it already applied.
          debugPrint('SYNC batch timeout: $e');
          await _syncIndividually(pending, branchId, deviceId);
          continue;
        } on SocketException catch (e) {
          debugPrint('Sync network error (offline): $e');
          return false;
        } catch (e) {
          debugPrint('SYNC batch error: $e');
          await _syncIndividually(pending, branchId, deviceId);
          continue;
        }

        debugPrint('SYNC response: ${response.statusCode}');

        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            final body = jsonDecode(response.body);
            if (body['success'] == true) {
              await DBHelper.markQueueSynced(ids);

              if (body['deltasUnapplied'] != null &&
                  (body['deltasUnapplied'] as num) > 0) {
                debugPrint(
                  'SYNC WARNING: ${body['deltasUnapplied']} movements did not '
                  'apply on the server — check its logs',
                );
              }

              // Adopt the server's totals for this batch. It has seen every
              // device; we have not.
              if (body['items'] is List) {
                await DBHelper.applyServerItems(body['items'] as List);
              }
              continue;
            }

            debugPrint('Batch rejected. Falling back to individual sync...');
            await _syncIndividually(pending, branchId, deviceId);
            continue;
          } catch (e) {
            debugPrint('Sync failed: invalid response. $e');
            await _syncIndividually(pending, branchId, deviceId);
            continue;
          }
        }

        debugPrint('Batch HTTP ${response.statusCode}. Falling back...');
        await _syncIndividually(pending, branchId, deviceId);
        continue;
      }
    } on TimeoutException catch (e) {
      debugPrint('Sync timeout: $e');
      return false;
    } on SocketException catch (e) {
      debugPrint('Sync network error (offline): $e');
      return false;
    } catch (e) {
      debugPrint('SyncService critical error: $e');
      return false;
    } finally {
      // Always released, on every path. The old code set this in each catch
      // block individually and could leak a stuck `true` on an unexpected
      // return, blocking every later sync.
      _isSyncing = false;
    }
  }

  Future<void> _syncIndividually(
    List<Map<String, dynamic>> pendingRows,
    String branchId,
    String deviceId,
  ) async {
    debugPrint('>>> _syncIndividually: ${pendingRows.length} rows');

    for (final row in pendingRows) {
      final id = row['id'] as int;
      final entityType = row['entityType']?.toString() ?? '';
      final operation = row['operation']?.toString() ?? '';

      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(row['payload']?.toString() ?? '{}')
            as Map<String, dynamic>;
      } catch (e) {
        await DBHelper.markQueueError(id, 'Invalid JSON payload');
        continue;
      }

      final Map<String, dynamic> requestBody = {
        'syncVersion': syncVersion,
        'deviceId': deviceId,
        'items': <Map<String, dynamic>>[],
        'editItems': <Map<String, dynamic>>[],
        'deleteItems': <String>[],
        'sales': <Map<String, dynamic>>[],
        'history': <Map<String, dynamic>>[],
        'stockTake': <Map<String, dynamic>>[],
      };

      switch (entityType) {
        case 'item':
          if (operation == 'delete') {
            requestBody['deleteItems'] = [payload['barcode']?.toString() ?? ''];
          } else if (operation == 'edit') {
            requestBody['editItems'] = [payload];
          } else {
            requestBody['items'] = [payload];
          }
          break;
        case 'sale':
          requestBody['sales'] = [payload];
          break;
        case 'history':
          requestBody['history'] = [payload];
          break;
        case 'stockTake':
          requestBody['stockTake'] = [payload];
          break;
        default:
          await DBHelper.markQueueError(id, 'Unknown entityType: $entityType');
          continue;
      }

      try {
        final response = await http
            .post(
              Uri.parse('$baseUrl/api/$branchId/sync'),
              headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
              },
              body: jsonEncode(requestBody),
            )
            .timeout(const Duration(seconds: 60));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final body = jsonDecode(response.body);
          if (body['success'] == true) {
            await DBHelper.markQueueSynced([id]);
          } else {
            await DBHelper.markQueueError(
              id,
              body['error']?.toString() ?? 'Unknown server error',
            );
          }
        } else {
          await DBHelper.markQueueError(
            id,
            'HTTP ${response.statusCode}: ${response.body}',
          );
        }
      } on TimeoutException {
        await DBHelper.markQueueError(id, 'Timeout during individual sync');
        continue;
      } on SocketException {
        break; // offline — stop, don't burn attempts on the rest
      } catch (e) {
        await DBHelper.markQueueError(id, 'Individual sync failed: $e');
        continue;
      }
    }
  }

  // =========================================================================
  // PULL
  // =========================================================================

  Future<bool> pullFromServer({required String branchId}) async {
    try {
      debugPrint('>>> pullFromServer start: $branchId');

      // Refuse to pull while work is still queued — the server's totals
      // wouldn't include it yet, and local stock would flicker backwards.
      final stillPending = await DBHelper.getPendingSyncCount(branchId);
      if (stillPending > 0) {
        debugPrint('>>> skipping pull: $stillPending rows still pending');
        return false;
      }

      // ---- Items -------------------------------------------------------
      http.Response itemsRes;
      try {
        itemsRes = await http
            .get(
              Uri.parse('$baseUrl/api/$branchId/items'),
              headers: {'x-api-key': apiKey},
            )
            .timeout(const Duration(seconds: 60));
      } catch (e) {
        debugPrint('>>> items request failed: $e');
        return false;
      }

      if (itemsRes.statusCode == 200) {
        final body = jsonDecode(itemsRes.body);
        if (body['success'] == true) {
          final List items = body['data'] as List? ?? [];
          debugPrint('>>> items count: ${items.length}');

          final Set<String> serverBarcodes = {};
          for (final item in items) {
            final barcode = item['barcode']?.toString() ?? '';
            if (barcode.isNotEmpty) serverBarcodes.add(barcode);
            await DBHelper.upsertItemFromServer(Map<String, dynamic>.from(item));
          }

          // Reap items the server no longer has.
          //
          // GUARD: never do this on an empty server list. A blank-but-
          // successful response would otherwise wipe the entire local
          // catalogue on every device at once.
          if (items.isNotEmpty) {
            await _reapDeletedItems(branchId, serverBarcodes);
          } else {
            debugPrint('>>> server returned 0 items — skipping local cleanup');
          }
        }
      }

      // ---- Sales -------------------------------------------------------
      try {
        final salesRes = await http
            .get(
              Uri.parse('$baseUrl/api/$branchId/sales'),
              headers: {'x-api-key': apiKey},
            )
            .timeout(const Duration(seconds: 60));

        if (salesRes.statusCode == 200) {
          final body = jsonDecode(salesRes.body);
          if (body['success'] == true) {
            for (final sale in (body['data'] as List? ?? [])) {
              await DBHelper.upsertSaleFromServer(Map<String, dynamic>.from(sale));
            }
          }
        }
      } catch (e) {
        debugPrint('>>> sales request failed: $e');
      }

      // ---- History -----------------------------------------------------
      try {
        final historyRes = await http
            .get(
              Uri.parse('$baseUrl/api/$branchId/history'),
              headers: {'x-api-key': apiKey},
            )
            .timeout(const Duration(seconds: 60));

        if (historyRes.statusCode == 200) {
          final body = jsonDecode(historyRes.body);
          if (body['success'] == true) {
            for (final h in (body['data'] as List? ?? [])) {
              await DBHelper.upsertHistoryFromServer(Map<String, dynamic>.from(h));
            }
          }
        }
      } catch (e) {
        debugPrint('>>> history request failed: $e');
      }

      debugPrint('>>> pullFromServer done');
      return true;
    } catch (e) {
      debugPrint('pullFromServer error: $e');
      return false;
    }
  }

  Future<void> _reapDeletedItems(
    String branchId,
    Set<String> serverBarcodes,
  ) async {
    final pendingQueue = await DBHelper.getPendingSyncQueue(branchId);
    final Set<String> pendingBarcodes = {};

    for (final row in pendingQueue) {
      try {
        final payload =
            jsonDecode(row['payload']?.toString() ?? '{}') as Map<String, dynamic>;
        final barcode = payload['barcode']?.toString() ?? '';
        if (barcode.isNotEmpty) pendingBarcodes.add(barcode);
      } catch (_) {}
    }

    final localItems = await DBHelper.getItems();
    final db = await DBHelper.database;

    for (final localItem in localItems) {
      final localBarcode = localItem['barcode']?.toString() ?? '';
      if (localBarcode.isEmpty) continue;
      if (serverBarcodes.contains(localBarcode)) continue;
      if (pendingBarcodes.contains(localBarcode)) continue;

      await db.delete('items', where: 'barcode = ?', whereArgs: [localBarcode]);
      debugPrint('>>> removed local item dropped by server: $localBarcode');
    }
  }
}