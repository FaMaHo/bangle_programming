import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'screens/today_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/device_screen.dart';
import 'screens/server_screen.dart';
import 'screens/profile_screen.dart';
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

/// Checks whether the user has completed profile setup.
/// Shows [ProfileScreen] on first launch, then [MainNavigation] afterward.
class _AppEntry extends StatefulWidget {
  const _AppEntry();

  @override
  State<_AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<_AppEntry> {
  bool _isLoading = true;
  bool _profileComplete = false;

  @override
  void initState() {
    super.initState();
    _checkProfile();
  }

  Future<void> _checkProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool('profile_complete') ?? false;
    if (mounted) {
      setState(() {
        _profileComplete = complete;
        _isLoading = false;
      });
    }
  }

  void _onProfileComplete() {
    setState(() => _profileComplete = true);
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

    if (!_profileComplete) {
      return ProfileScreen(onProfileComplete: _onProfileComplete);
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

    if (result.needsRescan) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Server not reachable — please rescan QR code'),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 7),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          action: SnackBarAction(
            label: 'Rescan',
            textColor: Colors.white,
            onPressed: () => setState(() => _currentIndex = 3),
          ),
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
