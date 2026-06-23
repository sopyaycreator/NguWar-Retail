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

  Future<bool> syncPending({required String branchId}) async {
    if (_isSyncing) return false;
    _isSyncing = true;

    try {
      final pending = await DBHelper.getPendingSyncQueue(branchId);
      if (pending.isEmpty) {
        _isSyncing = false;
        return true;
      }

      final List<int> ids = [];
      final List<Map<String, dynamic>> items = [];
      final List<Map<String, dynamic>> sales = [];
      final List<Map<String, dynamic>> history = [];

      for (final row in pending) {
        final id = row['id'] as int;
        final entityType = row['entityType']?.toString() ?? '';
        final payloadText = row['payload']?.toString() ?? '{}';
        final payload = jsonDecode(payloadText) as Map<String, dynamic>;

        ids.add(id);

        if (entityType == 'item') {
          items.add(payload);
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
              'items': items,
              'sales': sales,
              'history': history,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final body = jsonDecode(response.body);
        if (body['success'] == true) {
          await DBHelper.markQueueSynced(ids);
          _isSyncing = false;
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
