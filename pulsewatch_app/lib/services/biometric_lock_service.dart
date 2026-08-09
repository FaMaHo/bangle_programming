import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

/// Optional biometric/device-PIN gate shown when the app is opened or
/// resumed from the background. Whether it's enabled is just a UX
/// preference (not a secret), so it lives in SharedPreferences like other
/// settings — the actual unlock check always goes through the OS.
///
/// Keys are scoped per-user (see AuthService.scopedKey) — otherwise one
/// account's lock preference would silently apply to (or be inherited by)
/// every other account that logs into the same device.
class BiometricLockService {
  static final BiometricLockService instance = BiometricLockService._init();
  BiometricLockService._init();

  final LocalAuthentication _localAuth = LocalAuthentication();

  static const _kEnabledKey = 'biometric_lock_enabled';
  static const _kAskedKey = 'biometric_lock_asked';

  /// Whether this device even has a usable biometric/PIN setup.
  Future<bool> isDeviceSupported() async {
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      return canCheck || isSupported;
    } catch (_) {
      return false;
    }
  }

  /// Off until the user explicitly opts in (see MainNavigation's one-time
  /// prompt) — locking a brand-new install before anyone has ever been
  /// asked just strands them on the lock screen with nothing to unlock
  /// with.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(await AuthService.instance.scopedKey(_kEnabledKey)) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(await AuthService.instance.scopedKey(_kEnabledKey), enabled);
  }

  /// Whether the user has already been shown the one-time "want to lock
  /// the app?" prompt — regardless of how they answered.
  Future<bool> hasAskedToEnable() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(await AuthService.instance.scopedKey(_kAskedKey)) ?? false;
  }

  Future<void> markAskedToEnable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(await AuthService.instance.scopedKey(_kAskedKey), true);
  }

  Future<bool> authenticate() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Unlock PulseWatch to view your health data',
        options: const AuthenticationOptions(
          biometricOnly: false, // allow device PIN/pattern as a fallback
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
