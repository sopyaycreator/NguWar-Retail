import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'main.dart';
import 'sync_service.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _appVersion = '';
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = 'Version: ${packageInfo.version}';
      });
    }
    await Future.delayed(const Duration(milliseconds: 800)); // brief splash

    final loggedIn = await AuthService.tryAutoLogin();

    if (!mounted) return;

    if (loggedIn && AuthService.currentUser != null) {
      final sync = SyncService();
      await sync.pullFromServer(branchId: AuthService.currentUser!.branchId);

      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
    } else {
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

@override
Widget build(BuildContext context) {
  return Scaffold(
    backgroundColor: const Color(0xFFF6F6F6),
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Main splash content
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.store,
                  size: 80,
                  color: Colors.amber,
                ),
                SizedBox(height: 16),
                Text(
                  'Welcome to Nguwar',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 24),
                CircularProgressIndicator(
                  color: Colors.amber,
                ),
              ],
            ),
          ),

          // Version number at the bottom
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 16,
              ),
              child: Text(
                _appVersion,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
}
