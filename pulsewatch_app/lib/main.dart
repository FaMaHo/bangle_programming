import 'package:flutter/material.dart';
import 'theme/app_theme.dart';
import 'screens/today_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/device_screen.dart';
import 'screens/server_screen.dart';
import 'screens/enroll_screen.dart';
import 'screens/login_screen.dart';
import 'screens/lock_screen.dart';
import 'services/auth_service.dart';
import 'services/biometric_lock_service.dart';
import 'services/server_service.dart';
import 'services/ble_service.dart';
import 'services/inference_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await InferenceService.initialize();
  runApp(const PulseWatchApp());
}


class PulseWatchApp extends StatelessWidget { 
  const PulseWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PulseWatch AI',
      theme: AppTheme.lightTheme,
      debugShowCheckedModeBanner: false,
      home: const _AppEntry(),
    );
  }
}

/// Routes between account setup and the main app based on whether the
/// device has a logged-in account. Owns the enroll/login toggle directly
/// (rather than pushing routes for it) so its own state — and the
/// onLoggedIn callback those screens hold — never gets torn down mid-flow.
class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isLoggedIn = false;
  bool _showLogin = false;
  bool _lockEnabled = false;
  bool _isUnlocked = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-lock whenever the app leaves the foreground, so a stolen/borrowed
  // unlocked phone doesn't leave health data exposed after backgrounding.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _lockEnabled) {
      setState(() => _isUnlocked = false);
    }
  }

  Future<void> _checkState() async {
    final loggedIn = await AuthService.instance.isLoggedIn();

    final lockEnabled = await BiometricLockService.instance.isEnabled() &&
        await BiometricLockService.instance.isDeviceSupported();

    if (mounted) {
      setState(() {
        _isLoggedIn = loggedIn;
        _lockEnabled = lockEnabled;
        _isUnlocked = !lockEnabled;
        _isLoading = false;
      });
    }
  }

  void _onLoggedIn() {
    setState(() => _isLoggedIn = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(
          child: CircularProgressIndicator(color: AppColors.primaryGreen),
        ),
      );
    }

    if (!_isLoggedIn) {
      return _showLogin
          ? LoginScreen(
              onLoggedIn: _onLoggedIn,
              onSwitchToEnroll: () => setState(() => _showLogin = false),
            )
          : EnrollScreen(
              onEnrolled: _onLoggedIn,
              onSwitchToLogin: () => setState(() => _showLogin = true),
            );
    }

    if (_lockEnabled && !_isUnlocked) {
      return LockScreen(onUnlocked: () => setState(() => _isUnlocked = true));
    }

    return const MainNavigation();
  }
}

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    TodayScreen(),
    InsightsScreen(),
    DeviceScreen(),
    ServerScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Also try on first load, not only on resume
    WidgetsBinding.instance.addPostFrameCallback((_) => _triggerAutoUpload());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _triggerAutoUpload();
      BleService().tryAutoReconnect(); // reconnect watch silently
    }
  }

  Future<void> _triggerAutoUpload() async {
    final server = ServerService.instance;
    if (!await server.shouldAutoUpload()) return;

    final result = await server.smartUpload();
    if (!mounted) return;

    if (result.needsLogin) {
      // Refresh token is dead — drop back to the login/enrollment flow.
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const _AppEntry()),
        (route) => false,
      );
    } else if (result.needsRescan) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not reach research server — check connection'),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } else if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('Auto-uploaded ${result.recordsUploaded} readings'),
          backgroundColor: AppColors.primaryGreen,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _screens[_currentIndex],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        backgroundColor: AppColors.cardBackground,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'Insights',
          ),
          NavigationDestination(
            icon: Icon(Icons.watch_outlined),
            selectedIcon: Icon(Icons.watch),
            label: 'Device',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_upload_outlined),
            selectedIcon: Icon(Icons.cloud_upload),
            label: 'Upload',
          ),
        ],
      ),
    );
  }
}
