import 'package:flutter/material.dart';
import '../main.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import '../services/biometric_lock_service.dart';
import '../services/server_service.dart';
import '../services/upload_consent_service.dart';
import '../widgets/app_bottom_sheet.dart';

/// Account, app, and data-upload settings — a bottom-nav tab rather than a
/// pushed route so it's reachable in one tap instead of buried behind the
/// Home screen's gear icon. Manual upload lives here too (folded into
/// "Data upload" below) since auto-upload already runs silently in the
/// background for the common case; this is specifically the fallback for
/// when something's gone wrong with it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ServerService _server = ServerService.instance;
  final TextEditingController _urlController = TextEditingController();

  String _displayName = '';
  String _patientId = '';
  bool _biometricSupported = false;
  bool _biometricEnabled = false;
  bool _uploadConsentGiven = true; // matches UploadConsentService's default-on

  int _pendingCount = 0;
  DateTime? _lastUploadTime;
  bool _isConnected = false;
  bool _isTesting = false;
  bool _showAdvanced = false;

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
    final url = await _server.getServerUrl();
    final pending = await _server.getPendingUploadCount();
    final lastUpload = await _server.getLastUploadTime();

    if (mounted) {
      setState(() {
        _displayName = name;
        _patientId = id;
        _biometricSupported = biometricSupported;
        _biometricEnabled = biometricEnabled;
        _uploadConsentGiven = uploadConsentGiven;
        if (url != null) _urlController.text = url;
        _pendingCount = pending;
        _lastUploadTime = lastUpload;
      });
      if (url != null && url.isNotEmpty) {
        _silentConnectionTest();
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
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

  // ─── Manual upload ─────────────────────────────────────────────────────

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _isConnected = false;
    });
    await _server.setServerUrl(_urlController.text.trim());
    final ok = await _server.testConnection();
    if (mounted) {
      setState(() {
        _isTesting = false;
        _isConnected = ok;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? 'Connected to server' : 'Could not connect'),
          backgroundColor: ok ? AppColors.primaryGreen : AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  // Silently re-checks connection on screen load — no snackbar, no spinner.
  Future<void> _silentConnectionTest() async {
    final ok = await _server.testConnection();
    if (mounted) setState(() => _isConnected = ok);
  }

  // No confirmation step before this — a consent gate made sense when
  // upload lived on its own tab someone could stumble into, but this is a
  // manual action from inside Settings that the user already deliberately
  // navigated to; asking "are you sure" again would just be friction. The
  // status sheet below shows what's actually happening (uploading, then
  // succeeded or exactly why it didn't) instead.
  Future<void> _startUpload() async {
    if (_urlController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please enter the server URL first'),
          backgroundColor: AppColors.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (_) => _UploadStatusSheet(onRun: _performUpload),
    );
  }

  Future<UploadResult> _performUpload() async {
    await _server.setServerUrl(_urlController.text.trim());

    final result = await _server.uploadData();

    final pending = await _server.getPendingUploadCount();
    final lastUpload = await _server.getLastUploadTime();
    if (mounted) {
      setState(() {
        _pendingCount = pending;
        _lastUploadTime = lastUpload;
      });
    }

    return result;
  }

  String _lastUploadLabel() {
    if (_lastUploadTime == null) return 'Never uploaded';
    final diff = DateTime.now().difference(_lastUploadTime!);
    if (diff.inMinutes < 1) return 'Uploaded just now';
    if (diff.inHours < 1) return 'Uploaded ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Uploaded ${diff.inHours}h ago';
    return 'Uploaded ${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: 24),
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
          const SizedBox(height: 12),
          _buildUploadCard(),
        ],
      ),
    );
  }

  // Manual upload — the fallback for when automatic upload has trouble
  // (see Settings' doc comment above). Most people never need this since
  // auto-upload just works quietly in the background.
  //
  // Shows what's actually pending (not yet uploaded), not the total 48h
  // reading count — the total was misleading once upload became
  // incremental, since it no longer reflects what a tap on "Upload now"
  // would actually send. Nothing pending disables the button instead of
  // leaving an always-tappable action with nothing for it to do.
  Widget _buildUploadCard() {
    final hasPending = _pendingCount > 0;
    final icon = hasPending ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.primaryGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppColors.primaryGreen, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Data upload',
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      hasPending
                          ? '$_pendingCount reading${_pendingCount == 1 ? '' : 's'} not yet uploaded'
                          : 'Everything is uploaded',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 46),
            child: Text(_lastUploadLabel(), style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: hasPending ? _startUpload : null,
              icon: Icon(icon, size: 18),
              label: Text(hasPending ? 'Upload now' : 'Up to date'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.primaryGreen,
                disabledForegroundColor: AppColors.textSecondary,
                side: BorderSide(color: (hasPending ? AppColors.primaryGreen : AppColors.textSecondary).withOpacity(0.4)),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const Text(
                    'Advanced: server address',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  Icon(
                    _showAdvanced ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_showAdvanced) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'https://pulsana.org',
                      hintStyle: TextStyle(color: AppColors.textSecondary.withOpacity(0.5), fontSize: 13),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      filled: true,
                      fillColor: AppColors.background,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.primaryGreen, width: 1.5),
                      ),
                    ),
                    keyboardType: TextInputType.url,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _isTesting ? null : _testConnection,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: _isConnected ? AppColors.primaryGreen.withOpacity(0.12) : AppColors.background,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _isConnected ? AppColors.primaryGreen : Colors.grey.withOpacity(0.3),
                      ),
                    ),
                    child: _isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryGreen),
                          )
                        : Icon(
                            _isConnected ? Icons.check_rounded : Icons.wifi_tethering_rounded,
                            color: _isConnected ? AppColors.primaryGreen : AppColors.textSecondary,
                            size: 18,
                          ),
                  ),
                ),
              ],
            ),
            if (_isConnected) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.circle, color: AppColors.primaryGreen, size: 8),
                  const SizedBox(width: 6),
                  const Text(
                    'Connected',
                    style: TextStyle(color: AppColors.primaryGreen, fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ],
          ],
        ],
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

// ─── Upload status sheet ────────────────────────────────────────────────────

/// Runs the upload as soon as it's shown and reflects exactly what's
/// happening — a spinner while in flight, then a checkmark and what
/// succeeded, or a specific reason it didn't (no internet, server down,
/// session expired, etc — see UploadResult.message).
class _UploadStatusSheet extends StatefulWidget {
  final Future<UploadResult> Function() onRun;

  const _UploadStatusSheet({required this.onRun});

  @override
  State<_UploadStatusSheet> createState() => _UploadStatusSheetState();
}

enum _UploadPhase { running, success, error }

class _UploadStatusSheetState extends State<_UploadStatusSheet> {
  _UploadPhase _phase = _UploadPhase.running;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final result = await widget.onRun();
    if (!mounted) return;
    setState(() {
      _phase = result.success ? _UploadPhase.success : _UploadPhase.error;
      _message = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppBottomSheetChrome(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_phase == _UploadPhase.running) ...[
            const SizedBox(height: 12),
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(strokeWidth: 3, color: AppColors.primaryGreen),
            ),
            const SizedBox(height: 18),
            const Text(
              'Uploading…',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 4),
            const Text(
              "Don't close the app while this finishes.",
              style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
          ] else ...[
            AppSheetIconBadge(
              icon: _phase == _UploadPhase.success ? Icons.check_rounded : Icons.error_outline_rounded,
              color: _phase == _UploadPhase.success ? AppColors.primaryGreen : AppColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              _phase == _UploadPhase.success ? 'Upload complete' : 'Upload failed',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_phase == _UploadPhase.success ? 'Done' : 'Close'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
