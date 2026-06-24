import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'main.dart';

class LoginScreen extends StatefulWidget {
  final bool
  canPop; // ← true = show back button (switch account), false = no back button (first launch)
  const LoginScreen({super.key, this.canPop = false});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final _loginUsernameCtrl = TextEditingController();
  final _loginPasswordCtrl = TextEditingController();
  final _signupUsernameCtrl = TextEditingController();
  final _signupPasswordCtrl = TextEditingController();
  final _signupShopNameCtrl = TextEditingController();

  bool _isLoading = false;
  bool _loginObscure = true;
  bool _signupObscure = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _loginUsernameCtrl.dispose();
    _loginPasswordCtrl.dispose();
    _signupUsernameCtrl.dispose();
    _signupPasswordCtrl.dispose();
    _signupShopNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    // ✅ Clean the username exactly like the server does
    final rawUsername = _loginUsernameCtrl.text.trim();
    final username = rawUsername.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]'),
      '',
    );
    final password = _loginPasswordCtrl.text.trim();

    if (username.isEmpty || password.isEmpty) {
      _showError('Please enter username and password.');
      return;
    }

    setState(() => _isLoading = true);
    final user = await AuthService.login(username, password);
    setState(() => _isLoading = false);

    if (user != null && mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomePage()),
        (route) => false,
      );
    } else {
      _showError('Invalid username or password.');
    }
  }

  Future<void> _signUp() async {
    final username = _signupUsernameCtrl.text.trim();
    final password = _signupPasswordCtrl.text.trim();
    final shopName = _signupShopNameCtrl.text.trim();

    if (username.isEmpty || password.isEmpty || shopName.isEmpty) {
      _showError('All fields are required.');
      return;
    }
    if (password.length < 4) {
      _showError('Password must be at least 4 characters.');
      return;
    }

    setState(() => _isLoading = true);
    final user = await AuthService.register(username, password, shopName);
    setState(() => _isLoading = false);

    if (user != null && mounted) {
      // ✅ Show the actual saved username before proceeding
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Account Created! 🎉'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your account has been created. Your login username is:',
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.amber),
                ),
                child: Text(
                  user.username, // ← shows the cleaned username e.g. "sopyaythwin"
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Please remember this username to sign in next time.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Got it!',
                style: TextStyle(color: Colors.black),
              ),
            ),
          ],
        ),
      );

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomePage()),
          (route) => false,
        );
      }
    } else {
      _showError('Username already taken or server error.');
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F6F6),
      // ✅ Show back button only if canPop is true
      appBar: widget.canPop
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.black),
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.store, size: 72, color: Colors.amber),
                const SizedBox(height: 8),
                const Text(
                  'ငုဝါ',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                Card(
                  child: Column(
                    children: [
                      TabBar(
                        controller: _tabController,
                        labelColor: Colors.amber.shade800,
                        indicatorColor: Colors.amber,
                        tabs: const [
                          Tab(text: 'Sign In'),
                          Tab(text: 'Sign Up'),
                        ],
                      ),
                      SizedBox(
                        height: 340,
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // ── LOGIN TAB ──
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  TextField(
                                    controller: _loginUsernameCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Username',
                                      prefixIcon: Icon(Icons.person),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  TextField(
                                    controller: _loginPasswordCtrl,
                                    obscureText: _loginObscure,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      prefixIcon: const Icon(Icons.lock),
                                      border: const OutlineInputBorder(),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _loginObscure
                                              ? Icons.visibility
                                              : Icons.visibility_off,
                                        ),
                                        onPressed: () => setState(
                                          () => _loginObscure = !_loginObscure,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: _isLoading ? null : _login,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.amber,
                                      ),
                                      child: _isLoading
                                          ? const CircularProgressIndicator()
                                          : const Text(
                                              'Sign In',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black,
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // ── SIGN UP TAB ──
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                children: [
                                  TextField(
                                    controller: _signupShopNameCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Shop Name',
                                      prefixIcon: Icon(Icons.store),
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _signupUsernameCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Username',
                                      prefixIcon: Icon(Icons.person),
                                      border: OutlineInputBorder(),
                                      helperText: 'Letters and numbers only',
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _signupPasswordCtrl,
                                    obscureText: _signupObscure,
                                    decoration: InputDecoration(
                                      labelText: 'Password',
                                      prefixIcon: const Icon(Icons.lock),
                                      border: const OutlineInputBorder(),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _signupObscure
                                              ? Icons.visibility
                                              : Icons.visibility_off,
                                        ),
                                        onPressed: () => setState(
                                          () =>
                                              _signupObscure = !_signupObscure,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: double.infinity,
                                    height: 48,
                                    child: ElevatedButton(
                                      onPressed: _isLoading ? null : _signUp,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.amber,
                                      ),
                                      child: _isLoading
                                          ? const CircularProgressIndicator()
                                          : const Text(
                                              'Create Account',
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black,
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
