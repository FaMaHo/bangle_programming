import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional biometric/device-PIN gate shown when the app is opened or
/// resumed from the background. Whether it's enabled is just a UX
/// preference (not a secret), so it lives in SharedPreferences like other
/// settings — the actual unlock check always goes through the OS.
class BiometricLockService {
  static final BiometricLockService instance = BiometricLockService._init();
  BiometricLockService._init();

  final LocalAuthentication _localAuth = LocalAuthentication();

  static const _kEnabledKey = 'biometric_lock_enabled';

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

  /// Defaults to on for supported devices — the researcher shouldn't have
  /// to opt in for basic protection of health data.
  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabledKey) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey, enabled);
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
