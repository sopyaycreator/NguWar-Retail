import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class UserSession {
  final int userId;
  final String username;
  final String branchId;
  final String shopName;
  final String token;

  UserSession({
    required this.userId,
    required this.username,
    required this.branchId,
    required this.shopName,
    required this.token,
  });

  Map<String, dynamic> toJson() => {
    'userId':   userId,
    'username': username,
    'branchId': branchId,
    'shopName': shopName,
    'token':    token,
  };

  factory UserSession.fromJson(Map<String, dynamic> j) => UserSession(
    userId:   j['userId'] as int,
    username: j['username'] as String,
    branchId: j['branchId'] as String,
    shopName: j['shopName'] as String,
    token:    j['token'] as String,
  );
}

class AuthService {
  static const _baseUrl    = 'http://z312050-6w40u2.ps11.zwhhosting.com';
  static const _sessionKey = 'user_session';

  static UserSession? currentUser;

  // ✅ Correct getters — uses dot notation, not map brackets
  static String? get currentShopName => currentUser?.shopName;
  static String? get currentUsername  => currentUser?.username;
  static String? get currentBranchId  => currentUser?.branchId;

  /// Try to restore session from SharedPreferences
  static Future<bool> tryAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionKey);
      if (raw == null) return false;
      currentUser = UserSession.fromJson(jsonDecode(raw));
      debugPrint('Auto-login: ${currentUser!.username} / ${currentUser!.branchId}');
      return true;
    } catch (e) {
      debugPrint('Auto-login failed: $e');
      return false;
    }
  }

  /// Login with username/password
  static Future<UserSession?> login(String username, String password) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['success'] == true) {
          currentUser = UserSession(
            userId:   0,
            username: body['username'],
            branchId: body['branchId'],
            shopName: body['shopName'],
            token:    body['token'],
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_sessionKey, jsonEncode(currentUser!.toJson()));
          return currentUser;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Login error: $e');
      return null;
    }
  }

  /// Register new account
  static Future<UserSession?> register(
      String username, String password, String shopName) async {
    try {
      final res = await http.post(
        Uri.parse('$_baseUrl/api/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'shopName': shopName,
        }),
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        if (body['success'] == true) {
          currentUser = UserSession(
            userId:   0,
            username: body['username'],
            branchId: body['branchId'],
            shopName: body['shopName'],
            token:    body['token'],
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_sessionKey, jsonEncode(currentUser!.toJson()));
          return currentUser;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Register error: $e');
      return null;
    }
  }

  /// Logout — clear session
  static Future<void> logout() async {
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }
}