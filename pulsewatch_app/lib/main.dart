import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/device_screen.dart';
import 'screens/server_screen.dart';
import 'screens/enroll_screen.dart';
import 'screens/landing_screen.dart';
import 'screens/login_screen.dart';
import 'screens/lock_screen.dart';
import 'onboarding/coach_mark_overlay.dart';
import 'services/auth_service.dart';
import 'services/background_sync_service.dart';
import 'services/biometric_lock_service.dart';
import 'services/server_service.dart';
import 'services/ble_service.dart';
import 'services/inference_service.dart';
import 'services/upload_consent_service.dart';
import 'widgets/app_bottom_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required once, before runApp, for FlutterForegroundTask's main-isolate
  // <-> TaskHandler-isolate messaging to work (see foreground_task_handler.dart).
  FlutterForegroundTask.initCommunicationPort();
  // Registers callbackDispatcher with the Android WorkManager plugin so a
  // periodic background sync task (scheduled from BleService once a watch
  // is connected — see BackgroundSyncService.ensureScheduled) can actually
  // fire later, including after the app isn't running at all. Must happen
  // before runApp for the same reason as initCommunicationPort() above:
  // the plugin needs to be wired up before anything could try to use it.
  if (Platform.isAndroid) {
    await BackgroundSyncService.instance.init();
  }
  try {
    await InferenceService.initialize();
  } catch (e) {
    // Same defensive reasoning as _checkState's try/catch below: a device
    // that can't load the ONNX native library (e.g. an ABI it wasn't built
    // for) shouldn't leave the user stuck on a blank screen forever just
    // because this one await never returned. Report generation will fail
    // later (InferenceService.isInitialized stays false) instead of the
    // whole app failing to start.
    print('InferenceService failed to initialize, continuing without it: $e');
  }
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
  bool _showLanding = true;
  bool _showLogin = false;
  bool _lockEnabled = false;
  bool _isUnlocked = true;
  // True only when this session's own EnrollScreen just created the
  // account — not on an ordinary sign-in — so the one-time walkthrough
  // (see MainNavigation) never replays for a returning user.
  bool _justEnrolled = false;

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
    bool loggedIn = false;
    bool lockEnabled = false;

    // This gates every app launch — nothing renders until it finishes. It's
    // not just AuthService.isLoggedIn() that's been hardened against a bad
    // secure-storage read; this try/catch is a backstop so that *any*
    // unexpected exception here falls back to "not logged in" instead of
    // leaving the user stuck on the loading spinner forever, which is what
    // happened when this had no error handling at all.
    try {
      loggedIn = await AuthService.instance.isLoggedIn();
      if (loggedIn) {
        // Points DatabaseHelper at this account's own file before Home (or
        // anything else) gets a chance to read from whatever database was
        // last open — see AuthService.switchActiveUser.
        await AuthService.instance.switchActiveUser(await AuthService.instance.getPatientId());
      }
      lockEnabled = await BiometricLockService.instance.isEnabled() &&
          await BiometricLockService.instance.isDeviceSupported();
    } catch (e) {
      print('Startup check failed, defaulting to logged-out: $e');
    }

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

  void _onEnrolled() {
    setState(() {
      _isLoggedIn = true;
      _justEnrolled = true;
    });
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
      if (_showLanding) {
        return LandingScreen(
          onGetStarted: () => setState(() => _showLanding = false),
          onSignIn: () => setState(() {
            _showLanding = false;
            _showLogin = true;
          }),
        );
      }

      return _showLogin
          ? LoginScreen(
              onLoggedIn: _onLoggedIn,
              onSwitchToEnroll: () => setState(() => _showLogin = false),
              onBack: () => setState(() => _showLanding = true),
            )
          : EnrollScreen(
              onEnrolled: _onEnrolled,
              onSwitchToLogin: () => setState(() => _showLogin = true),
              onBack: () => setState(() => _showLanding = true),
            );
    }

    if (_lockEnabled && !_isUnlocked) {
      return LockScreen(onUnlocked: () => setState(() => _isUnlocked = true));
    }

    return MainNavigation(showWalkthrough: _justEnrolled);
  }
}

class MainNavigation extends StatefulWidget {
  final bool showWalkthrough;

  const MainNavigation({super.key, this.showWalkthrough = false});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _currentIndex = 0;
  bool _showingWalkthrough = false;

  // Spotlight anchors for the new-signup coach-mark walkthrough.
  final _watchStatusKey = GlobalKey();
  final _progressCardKey = GlobalKey();
  final _navBarKey = GlobalKey();

  List<Widget> get _screens => [
        HomeScreen(
          onNavigateToTab: _navigateToTab,
          watchStatusKey: _watchStatusKey,
          progressCardKey: _progressCardKey,
        ),
        const InsightsScreen(),
        const DeviceScreen(),
        const ServerScreen(),
      ];

  void _navigateToTab(int index) {
    setState(() => _currentIndex = index);
  }

  @override
  void initState() {
    super.initState();
    _showingWalkthrough = widget.showWalkthrough;
    WidgetsBinding.instance.addObserver(this);
    // Also try on first load, not only on resume — didChangeAppLifecycleState
    // only fires on a background->foreground *transition*, which a cold
    // start (app fully closed, then reopened) never triggers. Without this,
    // reopening the app after the BLE connection had already died left it
    // disconnected until the user noticed and manually reconnected.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerAutoUpload();
      _maybeCheckUploadHealth();
      BleService().tryAutoReconnect();
      // New signups get asked once the walkthrough finishes (see
      // onFinished below) so it doesn't compete with the coach marks;
      // everyone else (including existing users who've never seen these
      // prompts) gets asked here, on their next normal Home landing.
      if (!_showingWalkthrough) {
        _maybeShowFirstRunPrompts();
      }
    });
  }

  /// Runs the app's one-time opt-in prompts in order. Each one is asked
  /// exactly once ever (regardless of the answer) and none of them are
  /// bundled with the OS permission dialogs or the coach-mark walkthrough,
  /// so a new user isn't hit with everything at once.
  ///
  /// _maybeShowUploadConsentPrompt is intentionally NOT called here right
  /// now — automatic upload ships on-by-default for this launch (see
  /// UploadConsentService's doc comment for the reasoning and how to
  /// switch back to an opt-in flow later). The method is kept below,
  /// fully working, for exactly that switch — just add the call back.
  Future<void> _maybeShowFirstRunPrompts() async {
    await _maybeShowBiometricLockPrompt();
  }

  /// One-time opt-in for automatic background upload — currently unused
  /// by the flow above (see that method's doc comment), kept working for
  /// when this becomes an opt-in prompt again later.
  // ignore: unused_element
  Future<void> _maybeShowUploadConsentPrompt() async {
    final consent = UploadConsentService.instance;
    if (await consent.hasAsked()) return;
    if (!mounted) return;

    final allow = await showAppConfirmSheet(
      context: context,
      icon: Icons.cloud_upload_rounded,
      iconColor: AppColors.primaryGreen,
      title: 'Share your data automatically?',
      body: 'PulseWatch can send your heart rate and movement readings to '
          'the research server in the background, so you never have to '
          'upload manually.',
      primaryLabel: 'Allow',
      secondaryLabel: 'Not now',
      isDismissible: false,
      extra: const [
        AppSheetHint(
          icon: Icons.shield_outlined,
          text: 'Anonymized — your name and device ID are never included.',
        ),
        AppSheetHint(
          icon: Icons.settings_outlined,
          text: 'Change this anytime in Settings.',
        ),
      ],
    );

    await consent.setConsent(allow ?? false);
    await consent.markAsked();

    if (allow == true) {
      // The prompt itself only decides the setting; kick off an upload
      // right away if there's already a backlog waiting instead of
      // leaving it for the next launch/resume.
      _triggerAutoUpload();
    }
  }

  /// One-time opt-in for the app lock, asked once ever regardless of the
  /// answer — never re-shown, and never bundled with the OS permission
  /// dialogs or the coach-mark walkthrough so it doesn't add to that pile.
  Future<void> _maybeShowBiometricLockPrompt() async {
    final lock = BiometricLockService.instance;
    if (await lock.hasAskedToEnable()) return;
    if (!await lock.isDeviceSupported()) {
      await lock.markAskedToEnable();
      return;
    }
    if (!mounted) return;

    // Enabling requires a real, successful check first — never flip the
    // setting on trust alone. See _BiometricLockPromptDialog for the
    // verify-then-enable flow.
    final enabled = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      backgroundColor: Colors.transparent,
      builder: (context) => const _BiometricLockPromptDialog(),
    );

    if (enabled == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('App lock enabled')),
      );
    }
    await lock.markAskedToEnable();
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
      _maybeCheckUploadHealth();
      BleService().tryAutoReconnect(); // reconnect watch silently
    }
  }

  /// The active, foreground half of the upload-health signal (the
  /// background task in background_sync_service.dart handles the passive
  /// notification half even when the app isn't open). Only the
  /// backlog-risk case gets an in-app popup — a "no connection" is left to
  /// the banner HomeScreen reads directly from checkUploadHealth, since
  /// there's nothing actionable to walk the user through beyond "connect
  /// to the internet".
  Future<void> _maybeCheckUploadHealth() async {
    if (!await UploadConsentService.instance.hasConsented()) return;

    final server = ServerService.instance;
    if (await server.checkUploadHealth() != UploadHealth.backlogRisk) return;
    if (!await server.shouldShowBacklogPopup()) return;
    if (!mounted) return;

    await server.markBacklogPopupShown();

    final goUpload = await showAppConfirmSheet(
      context: context,
      icon: Icons.cloud_off_rounded,
      iconColor: AppColors.error,
      title: 'Your data needs uploading',
      body: "PulseWatch hasn't been able to reach the server in over 12 "
          "hours, even though you're connected. Let's upload manually to "
          'make sure nothing is lost.',
      primaryLabel: 'Upload now',
      secondaryLabel: 'Later',
    );

    if (goUpload == true) {
      _navigateToTab(3);
    }
  }

  Future<void> _triggerAutoUpload() async {
    if (!await UploadConsentService.instance.hasConsented()) return;

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
    final scaffold = Scaffold(
      body: SafeArea(
        child: _screens[_currentIndex],
      ),
      bottomNavigationBar: NavigationBar(
        key: _navBarKey,
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        backgroundColor: AppColors.cardBackground,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
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

    if (!_showingWalkthrough) return scaffold;

    return CoachMarkOverlay(
      steps: [
        CoachMarkStep(
          targetKey: _watchStatusKey,
          title: 'Connect your watch',
          description: 'Pair it once here — it reconnects on its own after that.',
        ),
        CoachMarkStep(
          targetKey: _progressCardKey,
          title: 'Wear it for 48 hours',
          description: 'Your risk report is calculated once, from your full session '
              '— not a quick snapshot.',
        ),
        CoachMarkStep(
          targetKey: _navBarKey,
          title: 'Find your way around',
          description: 'Insights shows trends, Device handles connection and '
              'diagnostics, and Upload sends data to the research server.',
        ),
      ],
      onFinished: () {
        setState(() => _showingWalkthrough = false);
        _maybeShowFirstRunPrompts();
      },
      child: scaffold,
    );
  }
}

/// The one-time "want to lock the app?" prompt. Tapping Enable runs a real
/// authentication check on the spot — the setting only turns on if that
/// check actually succeeds, so a cancelled or failed attempt (wet fingers,
/// declined prompt, whatever) never leaves the lock silently enabled with
/// no way back in. A failed check stays on the dialog so the user can
/// retry, rather than closing and guessing what happened.
class _BiometricLockPromptDialog extends StatefulWidget {
  const _BiometricLockPromptDialog();

  @override
  State<_BiometricLockPromptDialog> createState() => _BiometricLockPromptDialogState();
}

class _BiometricLockPromptDialogState extends State<_BiometricLockPromptDialog> {
  bool _verifying = false;
  bool _lastAttemptFailed = false;

  Future<void> _verifyAndEnable() async {
    setState(() {
      _verifying = true;
      _lastAttemptFailed = false;
    });

    final success = await BiometricLockService.instance.authenticate();

    if (!mounted) return;

    if (success) {
      await BiometricLockService.instance.setEnabled(true);
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _verifying = false;
        _lastAttemptFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBottomSheetChrome(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const AppSheetIconBadge(icon: Icons.fingerprint, color: AppColors.primaryGreen),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                tooltip: 'Close',
                onPressed: _verifying ? null : () => Navigator.of(context).pop(false),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Lock PulseWatch?',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          const Text(
            'Require your fingerprint or PIN to open the app.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
          ),
          const AppSheetHint(
            icon: Icons.settings_outlined,
            text: 'Change this anytime in Settings.',
          ),
          if (_lastAttemptFailed)
            const AppSheetHint(
              icon: Icons.error_outline,
              text: 'Couldn\'t verify — try again, or use PIN/pattern if biometrics '
                  'aren\'t working right now.',
              color: AppColors.error,
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _verifying ? null : _verifyAndEnable,
              child: _verifying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Enable'),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _verifying ? null : () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
          ),
        ],
      ),
    );
  }
}
