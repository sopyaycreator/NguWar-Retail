import 'dart:convert';
import 'package:http/http.dart' as http;

class AuthUser {
  final String token;
  final String branchId;
  final String shopName;
  final String username;

  AuthUser({
    required this.token,
    required this.branchId,
    required this.shopName,
    required this.username,
  });
}

class AuthService {
  static const String baseUrl = 'http://z312050-6w40u2.ps11.zwhhosting.com';

  // Holds the currently logged-in user in memory
  static AuthUser? currentUser;

  static Future<AuthUser?> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['success'] == true) {
          currentUser = AuthUser(
            token: body['token'],
            branchId: body['branchId'],
            shopName: body['shopName'],
            username: body['username'],
          );
          return currentUser;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static void logout() {
    currentUser = null;
  }
}