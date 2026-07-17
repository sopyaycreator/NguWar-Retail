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
        _appVersion = 'v${packageInfo.version}'; // e.g., "v2.1.0"
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
    return  Scaffold(
      backgroundColor: Color(0xFFF6F6F6),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
            children: [
            const Icon(Icons.store, size: 80, color: Colors.amber),
            const SizedBox(height: 16),
            const Text('Welcome to Nguwar',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: Colors.amber),
            const SizedBox(height: 24), // Spacing before version
            // Display the version fetched dynamically
            Text(
              _appVersion, 
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
