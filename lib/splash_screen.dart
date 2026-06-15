import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToHome();
  }

  Future<void> _navigateToHome() async {
    // Wait 3.5 seconds to show off the beautiful entry animations
    await Future.delayed(const Duration(milliseconds: 3500));
    
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const HomePage(),
         
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Matches your white adaptive icon background
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Spacer(flex: 3),

            // 📲 1. ANIMATED LOGO
            Container(
              width: 120,
              height: 120,
              alignment: Alignment.center,
              child: Image.asset(
                "assets/images/app_logo.jpg",
                fit: BoxFit.contain,
              ),
            )
            .animate()
            .fadeIn(duration: 800.ms, curve: Curves.easeOut) // Fades in smoothly
            .scale(delay: 100.ms, duration: 800.ms, begin: const Offset(0.7, 0.7), curve: Curves.elasticOut) // Bounces slightly up
            .then(delay: 300.ms) // Waits a moment after entering
            .shimmer(duration: 1200.ms, color: Colors.white54), // Runs a premium metallic gloss shine overlay across your logo image

            const SizedBox(height: 24),

            // 🏷️ 2. ANIMATED TEXT TITLE
            Text(
              "ငုဝါ", // Your app name from pubspec
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
                color: Colors.grey.shade900,
              ),
            )
            .animate()
            .fadeIn(delay: 400.ms, duration: 600.ms) // Appears slightly after the logo
            .slideY(begin: 0.3, end: 0, curve: Curves.easeOut), // Slides up into place neatly

            const SizedBox(height: 8),

            // 📝 3. ANIMATED SUBTITLE
            Text(
              "Smart Retail & Store Ledger",
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w400,
              ),
            )
            .animate()
            .fadeIn(delay: 700.ms, duration: 500.ms),

            const Spacer(flex: 2),

            // ⏳ 4. ANIMATED PROGRESS LOADER
            Column(
              children: [
                SizedBox(
                  width: 40,
                  child: const LinearProgressIndicator(
                    backgroundColor: Color(0xFFE0E0E0),
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.black),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  "Initializing system database...",
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400, letterSpacing: 0.5),
                ),
              ],
            )
            .animate()
            .fadeIn(delay: 1000.ms, duration: 400.ms), // Fades in at the bottom at the very end
            
            const Spacer(),
          ],
        ),
      ),
    );
  }
}