import 'package:flutter/material.dart';
import '../main.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/biometric_lock_service.dart';
import '../services/server_service.dart';

/// Account and app settings — separate from the Upload page, which is
/// about where data goes rather than who the user is.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _displayName = '';
  String _patientId = '';
  bool _biometricSupported = false;
  bool _biometricEnabled = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final name = await ServerService.instance.getDisplayName();
    final id = await ServerService.instance.getPatientId();
    final biometricSupported = await BiometricLockService.instance.isDeviceSupported();
    final biometricEnabled = await BiometricLockService.instance.isEnabled();

    if (mounted) {
      setState(() {
        _displayName = name;
        _patientId = id;
        _biometricSupported = biometricSupported;
        _biometricEnabled = biometricEnabled;
      });
    }
  }

  Future<void> _toggleBiometricLock(bool value) async {
    await BiometricLockService.instance.setEnabled(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You\'ll need your username and password (or a new enrollment code) to log back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log out', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await AuthService.instance.logout();
    if (!mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PulseWatchApp()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        title: const Text(
          'Settings',
          style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ProfileCard(
              displayName: _displayName,
              patientId: _patientId,
              onLogout: _logout,
            ),
            if (_biometricSupported) ...[
              const SizedBox(height: 12),
              _AppLockToggle(enabled: _biometricEnabled, onChanged: _toggleBiometricLock),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  final String displayName;
  final String patientId;
  final VoidCallback onLogout;

  const _ProfileCard({
    required this.displayName,
    required this.patientId,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.person_rounded,
                color: AppColors.primaryGreen, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName.isEmpty ? 'Participant' : displayName,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.shield_rounded,
                        color: AppColors.primaryGreen, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      'Research ID: $patientId',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: AppColors.textSecondary, size: 20),
            tooltip: 'Log out',
            onPressed: onLogout,
          ),
        ],
      ),
    );
  }
}

class _AppLockToggle extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _AppLockToggle({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.fingerprint_rounded, color: AppColors.primaryGreen, size: 22),
          const SizedBox(width: 14),
          const Expanded(
            child: Text(
              'App lock',
              style: TextStyle(
                  color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          Switch(
            value: enabled,
            onChanged: onChanged,
            activeColor: AppColors.primaryGreen,
          ),
        ],
      ),
    );
  }
}
