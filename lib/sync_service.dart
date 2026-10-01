import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'db_helper.dart';

/// The outcome of a sync cycle.
///
/// The old code returned a bare `bool`, which could not distinguish
/// "everything arrived" from "the queue is empty because I gave up on a
/// day's worth of sales". That is why the UI showed a green tick while
/// 14 August sat dead on the device.
class SyncResult {
  /// Queue fully drained AND the pull succeeded.
  final bool ok;

  /// Rows still waiting. They will be retried automatically.
  final int stillPending;

  /// Rows given up on. These need attention — they are NOT retried
  /// automatically except once per app launch.
  final int parked;

  final String? note;

  const SyncResult({
    required this.ok,
    this.stillPending = 0,
    this.parked = 0,
    this.note,
  });
  

  bool get hasUnsentData => stillPending > 0 || parked > 0;

  /// One line, safe to drop straight into a SnackBar.
  String get summary {
    if (ok && !hasUnsentData) return 'Sync complete';
    if (parked > 0 && stillPending > 0) {
      return 'Sync incomplete — $stillPending queued, $parked failed';
    }
    if (parked > 0) return 'Sync incomplete — $parked items failed to send';
    if (stillPending > 0) return 'Sync incomplete — $stillPending items queued';
    return note ?? 'Sync incomplete';
  }
}

class SyncService {
  static const String baseUrl = 'https://z312050-6w40u2.ps11.zwhhosting.com';
  static const String apiKey = 'nguwar-pos-my-secret-2026';

  /// Tells the server this device speaks the delta protocol.
  static const int syncVersion = 2;

  /// Parked rows get one free retry per app launch. Safe: every movement
  /// carries a clientId and the server does INSERT IGNORE, so a re-send
  /// that already landed is skipped rather than applied twice.
  static bool _recoveredThisLaunch = false;
  bool _isPulling = false;

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

  // =========================================================================
  // FAILURE CLASSIFICATION — the core of the fix
  // =========================================================================

  /// Is this HTTP status a temporary condition worth waiting out?
  ///
  /// Your server returns 503 "Database busy, retry." straight from
  /// getConnection() when the pool (connectionLimit: 3) is exhausted. That
  /// is explicitly a *retry me later* signal. The old client counted it
  /// against the 5-attempt limit exactly like a malformed payload, so a
  /// busy afternoon was enough to permanently discard a day of sales.
  ///
  /// Retryable failures no longer burn an attempt, and they stop the cycle
  /// instead of hammering a server that has just said it is overloaded.
  static bool _isRetryableStatus(int statusCode) {
    return statusCode == 408 || // request timeout
        statusCode == 425 || // too early
        statusCode == 429 || // rate limited
        statusCode == 502 || // bad gateway
        statusCode == 503 || // YOUR "Database busy, retry."
        statusCode == 504; // gateway timeout
  }

  /// PUSH first, THEN pull. This order is mandatory.
  Future<SyncResult> synchronize({required String branchId}) async {
    final pushResult = await syncPending(branchId: branchId);
    if (!pushResult.ok) return pushResult;

    final pulled = await pullFromServer(branchId: branchId);

    return SyncResult(
      ok: pulled,
      stillPending: pushResult.stillPending,
      parked: pushResult.parked,
      note: pulled ? null : 'Could not read latest data from server',
    );
  }

  // =========================================================================
  // PUSH
  // =========================================================================

  Future<SyncResult> syncPending({required String branchId}) async {
    if (_isSyncing) {
      int retries = 0;
      while (_isSyncing && retries < 15) {
        await Future.delayed(const Duration(seconds: 1));
        retries++;
      }
      if (_isSyncing) {
        return const SyncResult(ok: false, note: 'Another sync is running');
      }
    }

    _isSyncing = true;

    try {
      final deviceId = await DBHelper.getDeviceId();

      // Give previously-parked rows one more chance, once per launch.
      if (!_recoveredThisLaunch) {
        _recoveredThisLaunch = true;
        final revived = await DBHelper.getParkedSyncCount(branchId);
        if (revived > 0) {
          debugPrint('SYNC: un-parking $revived failed rows for one retry');
          await DBHelper.recoverFailedTransactions();
        }
      }

      int loopGuard = 0;
      const int maxLoops = 200;

      while (true) {
        if (++loopGuard > maxLoops) {
          debugPrint('SYNC: loop guard hit — stopping, will resume next cycle');
          return SyncResult(
            ok: false,
            stillPending: await DBHelper.getPendingSyncCount(branchId),
            parked: await DBHelper.getParkedSyncCount(branchId),
            note: 'Too many batches in one cycle',
          );
        }

        final allPending = await DBHelper.getPendingSyncQueue(branchId);
        if (allPending.isEmpty) {
          final parked = await DBHelper.getParkedSyncCount(branchId);
          // The queue being empty is NOT the same as success. If rows were
          // parked, say so — do not report a clean sync.
          return SyncResult(ok: true, parked: parked);
        }

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
            // A payload that will not parse is permanently broken. Counting
            // it is correct.
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

        if (ids.isEmpty) continue;

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
          // shorter than its 180s. Re-sending is safe because of clientId.
          // But a timeout is NEVER the device's fault, so it must not count
          // toward parking.
          debugPrint('SYNC batch timeout: $e');
          await _markAllRetryable(ids, 'Batch timeout — server slow');
          return SyncResult(
            ok: false,
            stillPending: await DBHelper.getPendingSyncCount(branchId),
            parked: await DBHelper.getParkedSyncCount(branchId),
            note: 'Server too slow — will retry',
          );
        } on SocketException catch (e) {
          debugPrint('Sync network error (offline): $e');
          return SyncResult(
            ok: false,
            stillPending: await DBHelper.getPendingSyncCount(branchId),
            parked: await DBHelper.getParkedSyncCount(branchId),
            note: 'Offline',
          );
        } catch (e) {
          debugPrint('SYNC batch error: $e');
          await _syncIndividually(pending, branchId, deviceId);
          continue;
        }

        debugPrint('SYNC response: ${response.statusCode}');

        // ---- Temporary server trouble: back off, do not punish rows ----
        if (_isRetryableStatus(response.statusCode)) {
          debugPrint(
            'SYNC: server busy (HTTP ${response.statusCode}) — backing off',
          );
          await _markAllRetryable(
            ids,
            'Server busy (HTTP ${response.statusCode})',
          );
          return SyncResult(
            ok: false,
            stillPending: await DBHelper.getPendingSyncCount(branchId),
            parked: await DBHelper.getParkedSyncCount(branchId),
            note: 'Server busy — will retry automatically',
          );
        }

        if (response.statusCode >= 200 && response.statusCode < 300) {
          try {
            final body = jsonDecode(response.body);
            if (body['success'] == true) {
              await DBHelper.markQueueSynced(ids);

              final unapplied = body['deltasUnapplied'];
              if (unapplied != null && (unapplied as num) > 0) {
                debugPrint(
                  'SYNC WARNING: $unapplied movements did not apply on the '
                  'server — an item row was missing or untracked',
                );
              }

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
      return const SyncResult(ok: false, note: 'Timed out');
    } on SocketException catch (e) {
      debugPrint('Sync network error (offline): $e');
      return const SyncResult(ok: false, note: 'Offline');
    } catch (e) {
      debugPrint('SyncService critical error: $e');
      return SyncResult(ok: false, note: 'Sync error: $e');
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _markAllRetryable(List<int> ids, String reason) async {
    for (final id in ids) {
      await DBHelper.markQueueRetryable(id, reason);
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

        if (_isRetryableStatus(response.statusCode)) {
          // Server is struggling. Stop the whole pass — continuing would
          // just queue up more failures against a server that told us to
          // wait, and every row after this one would be punished too.
          await DBHelper.markQueueRetryable(
            id,
            'Server busy (HTTP ${response.statusCode})',
          );
          debugPrint('>>> server busy — aborting individual pass');
          break;
        }

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
        // Not the row's fault. Do not count it.
        await DBHelper.markQueueRetryable(id, 'Timeout during individual sync');
        continue;
      } on SocketException {
        break; // offline — stop, don't burn attempts on the rest
      } catch (e) {
        await DBHelper.markQueueRetryable(id, 'Network problem: $e');
        continue;
      }
    }
  }

  // =========================================================================
  // PULL
  // =========================================================================

  Future<bool> pullFromServer({required String branchId}) async {
     if (_isPulling) {
      debugPrint('>>> pull already running — skipping');
      return false;
    }
    _isPulling = true;
    try {
      debugPrint('>>> pullFromServer start: $branchId');

      final stillPending = await DBHelper.getPendingSyncCount(branchId);
      if (stillPending > 0) {
        debugPrint('>>> skipping pull: $stillPending rows still pending');
        return false;
      }
        

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
              await DBHelper.upsertSaleFromServer(
                Map<String, dynamic>.from(sale),
              );
            }
          }
        }
      } catch (e) {
        debugPrint('>>> sales request failed: $e');
      }

      // ---- Item history ------------------------------------------------
      // /history is paginated on the server. The old code called it once,
      // therefore the phone only received the newest page (500 by default).
      // This helper performs a one-time historical backfill, then future
      // syncs use sinceId so we only download newly-added history rows.
      final historyOk = await _pullHistory(branchId);
      if (!historyOk) {
        debugPrint('>>> history pull incomplete');
        return false;
      }

      debugPrint('>>> pullFromServer done');
      return true;
    } catch (e) {
      debugPrint('pullFromServer error: $e');
      return false;
    } finally {
      _isPulling = false;
    }
  }


  static const int _historyPageSize = 1000;

  Future<Map<String, dynamic>?> _getHistoryPage(
    String branchId, {
    int? sinceId,
    int? offset,
  }) async {
    final params = <String, String>{
      'limit': _historyPageSize.toString(),
    };
    if (sinceId != null) params['sinceId'] = sinceId.toString();
    if (offset != null) params['offset'] = offset.toString();

    final uri = Uri.parse('$baseUrl/api/$branchId/history').replace(
      queryParameters: params,
    );

    try {
      final response = await http
          .get(uri, headers: {'x-api-key': apiKey})
          .timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        debugPrint(
          '>>> history HTTP ${response.statusCode}: ${response.body}',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        debugPrint('>>> history response was not successful');
        return null;
      }
      return decoded;
    } on TimeoutException catch (e) {
      debugPrint('>>> history timeout: $e');
      return null;
    } on SocketException catch (e) {
      debugPrint('>>> history offline: $e');
      return null;
    } catch (e) {
      debugPrint('>>> history request failed: $e');
      return null;
    }
  }

  Future<void> _saveHistoryRows(List rows) async {
    for (final h in rows) {
      if (h is Map) {
        await DBHelper.upsertHistoryFromServer(
          Map<String, dynamic>.from(h),
        );
      }
    }
  }

  int? _historyServerId(dynamic row) {
    if (row is! Map) return null;
    return int.tryParse((row['id'] ?? row['serverId'] ?? '').toString());
  }

  Future<int?> _latestLocalHistoryServerId() async {
    final db = await DBHelper.database;
    final rows = await db.rawQuery(
      'SELECT MAX(serverId) AS value '
      'FROM item_history WHERE serverId IS NOT NULL',
    );
    final value = rows.first['value'];
    if (value == null) return null;
    return (value as num).toInt();
  }

  Future<bool> _historyBackfillIsComplete(String branchId) async {
    final db = await DBHelper.database;
    final key = 'historyBackfillComplete:$branchId';
    final rows = await db.query(
      'app_meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty && rows.first['value']?.toString() == '1';
  }

  Future<void> _markHistoryBackfillComplete(String branchId) async {
    final db = await DBHelper.database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO app_meta(key, value) VALUES(?, ?)',
      ['historyBackfillComplete:$branchId', '1'],
    );
  }

  Future<bool> _pullHistory(String branchId) async {
    // 1) Normal sync: download only history rows newer than the highest
    // serverId already stored on this phone.
    int? latestId = await _latestLocalHistoryServerId();

    if (latestId != null) {
      int cursor = latestId;

      while (true) {
        final body = await _getHistoryPage(branchId, sinceId: cursor);
        if (body == null) return false;

        final List rows = body['data'] as List? ?? const [];
        if (rows.isEmpty) break;

        await _saveHistoryRows(rows);

        final ids = rows.map(_historyServerId).whereType<int>().toList();
        if (ids.isEmpty) break;

        final nextCursor = ids.reduce((a, b) => a > b ? a : b);
        if (nextCursor <= cursor) break;
        cursor = nextCursor;

        if (rows.length < _historyPageSize) break;
      }
    }

    // 2) One-time backfill. This is the part your old sync was missing.
    // Your current Express route already supports limit + offset, so there
    // is no backend change required for this version.
    final backfillDone = await _historyBackfillIsComplete(branchId);

    // If there is no local server history at all, backfill even if a stale
    // marker somehow exists (for example after local history was cleared).
    latestId = await _latestLocalHistoryServerId();
    if (!backfillDone || latestId == null) {
      int offset = 0;
      int totalReceived = 0;

      while (true) {
        final body = await _getHistoryPage(branchId, offset: offset);
        if (body == null) return false;

        final List rows = body['data'] as List? ?? const [];
        debugPrint(
          '>>> history backfill: offset=$offset, received=${rows.length}',
        );

        if (rows.isEmpty) break;

        await _saveHistoryRows(rows);
        totalReceived += rows.length;

        if (rows.length < _historyPageSize) break;
        offset += rows.length;
      }

      await _markHistoryBackfillComplete(branchId);
      debugPrint('>>> history backfill complete: $totalReceived rows');
    }

    return true;
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
            jsonDecode(row['payload']?.toString() ?? '{}')
                as Map<String, dynamic>;
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