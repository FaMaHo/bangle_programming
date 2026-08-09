import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

/// Whether the app is allowed to upload collected data to the research
/// server automatically, in the background. Manual upload from the Upload
/// tab has its own separate per-upload consent sheet and isn't affected by
/// this.
///
/// Defaults to ON for this launch — the project needs the data, so this
/// ships as opt-out rather than opt-in: no first-run prompt, but turning
/// it off in Settings shows an explanatory sheet asking the user to
/// reconsider before it takes effect (see SettingsScreen._toggleUploadConsent).
/// The original opt-in prompt (MainNavigation._maybeShowUploadConsentPrompt)
/// is deliberately left in place, fully working, just not called from the
/// active first-run sequence — the plan is to switch back to that once
/// enough data has been collected. If that switch happens, flip the
/// default below back to `false` too.
///
/// Keys are scoped per-user (see AuthService.scopedKey) — each account's
/// choice is its own, not inherited from whoever was last logged in on
/// this device.
class UploadConsentService {
  static final UploadConsentService instance = UploadConsentService._init();
  UploadConsentService._init();

  static const _kConsentKey = 'upload_consent_given';
  static const _kAskedKey = 'upload_consent_asked';

  Future<bool> hasConsented() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(await AuthService.instance.scopedKey(_kConsentKey)) ?? true;
  }

  Future<void> setConsent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(await AuthService.instance.scopedKey(_kConsentKey), value);
  }

  /// Whether the user has already been shown the one-time prompt —
  /// regardless of how they answered, or if they set it directly from
  /// Settings without ever seeing the prompt.
  Future<bool> hasAsked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(await AuthService.instance.scopedKey(_kAskedKey)) ?? false;
  }

  Future<void> markAsked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(await AuthService.instance.scopedKey(_kAskedKey), true);
  }
}
