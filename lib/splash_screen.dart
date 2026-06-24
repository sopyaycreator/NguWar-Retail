import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'login_screen.dart';
import 'main.dart';
import 'sync_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    await Future.delayed(const Duration(milliseconds: 800)); // brief splash

    final loggedIn = await AuthService.tryAutoLogin();

    if (!mounted) return;

    if (loggedIn && AuthService.currentUser != null) {
      // Pull latest data then go home
      final sync = SyncService();
      await sync.pullFromServer(branchId: AuthService.currentUser!.branchId);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF6F6F6),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.store, size: 80, color: Colors.amber),
            SizedBox(height: 16),
            Text('Nguwar',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            SizedBox(height: 24),
            CircularProgressIndicator(color: Colors.amber),
          ],
        ),
      ),
    );
  }
}