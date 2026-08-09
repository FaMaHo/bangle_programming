import 'package:flutter/material.dart';
import '../main.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/biometric_lock_service.dart';
import '../services/server_service.dart';
import '../services/upload_consent_service.dart';
import '../widgets/app_bottom_sheet.dart';

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
  bool _biometricEnabled = false;
  bool _uploadConsentGiven = true; // matches UploadConsentService's default-on

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
    final uploadConsentGiven = await UploadConsentService.instance.hasConsented();

    if (mounted) {
      setState(() {
        _displayName = name;
        _patientId = id;
        _biometricSupported = biometricSupported;
        _biometricEnabled = biometricEnabled;
        _uploadConsentGiven = uploadConsentGiven;
      });
    }
  }

  Future<void> _toggleBiometricLock(bool value) async {
    if (value) {
      // Never turn the lock on without confirming it actually works — a
      // failed/cancelled check (wet fingers, declined prompt) would
      // otherwise silently enable a lock with no way back in.
      final success = await BiometricLockService.instance.authenticate();
      if (!success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Couldn\'t verify — lock not enabled. Try again.')),
          );
        }
        return;
      }
    }
    await BiometricLockService.instance.setEnabled(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  Future<void> _toggleUploadConsent(bool value) async {
    if (!value) {
      // This is exactly the data the research project depends on, so
      // turning it off isn't a silent flip — explain why it matters and
      // give the user a chance to reconsider before it actually happens.
      final keepSharing = await showAppConfirmSheet(
        context: context,
        icon: Icons.science_outlined,
        iconColor: AppColors.primaryGreen,
        title: 'Before you turn this off',
        body: 'PulseWatch AI is a research project studying cardiac risk '
            'from everyday wearable data. Every reading you share helps '
            "train and validate the model — for you and for future "
            "participants. Turning this off means your data stops "
            'reaching the research team automatically.',
        primaryLabel: 'Keep sharing my data',
        secondaryLabel: 'Turn off anyway',
      );
      // Anything other than an explicit "Turn off anyway" (the secondary
      // button, which pops false) leaves the setting untouched — including
      // "Keep sharing" and dismissing the sheet without choosing.
      if (keepSharing != false) return;
    }

    await UploadConsentService.instance.setConsent(value);
    // If this is toggled from Settings before the one-time prompt was ever
    // shown, treat that as having answered — no need to still ask later.
    await UploadConsentService.instance.markAsked();
    if (mounted) setState(() => _uploadConsentGiven = value);
  }

  Future<void> _logout() async {
    final confirmed = await showAppConfirmSheet(
      context: context,
      icon: Icons.logout_rounded,
      iconColor: AppColors.error,
      title: 'Log out?',
      body: 'You\'ll need your username and password (or a new enrollment '
          'code) to log back in.',
      primaryLabel: 'Log out',
      secondaryLabel: 'Cancel',
      primaryIsDestructive: true,
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
              _SettingsToggle(
                icon: Icons.fingerprint_rounded,
                label: 'App lock',
                enabled: _biometricEnabled,
                onChanged: _toggleBiometricLock,
              ),
            ],
            const SizedBox(height: 12),
            _SettingsToggle(
              icon: Icons.cloud_upload_rounded,
              label: 'Automatic upload',
              enabled: _uploadConsentGiven,
              onChanged: _toggleUploadConsent,
            ),
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

class _SettingsToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SettingsToggle({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

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
          Icon(icon, color: AppColors.primaryGreen, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
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
