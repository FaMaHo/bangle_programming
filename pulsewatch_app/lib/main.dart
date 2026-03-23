import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'screens/today_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/device_screen.dart';
import 'screens/server_screen.dart';
import 'screens/profile_screen.dart';

void main() {
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

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    TodayScreen(),
    InsightsScreen(),
    DeviceScreen(),
    ServerScreen(),
  ];

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