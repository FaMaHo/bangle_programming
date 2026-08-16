import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Detects and works around OEM-specific "Autostart"/"Protected apps"
/// background-permission systems — MIUI (Xiaomi/Redmi/POCO), ColorOS
/// (Oppo/Realme), Funtouch OS (vivo/iQOO), EMUI (Huawei/Honor), and a few
/// others. This is a SEPARATE permission layer from Android's own
/// battery-optimization exemption (see BleService.requestBatteryExemption)
/// — granting one does not grant the other. These OEM skins block an app
/// from running any background service or receiving
/// RECEIVE_BOOT_COMPLETED at all unless this is explicitly turned on, and
/// most default it to *off* for a newly installed app. A watch that won't
/// reconnect/sync in the background on one of these phones, despite the
/// standard battery exemption already being granted, is exactly this.
///
/// There's no reliable public API to check whether autostart is currently
/// enabled — none of these OEM permission systems expose one — only to
/// open the settings screen for the user to check/enable it themselves.
/// So unlike the battery-exemption flow (which re-checks and re-nags if
/// revoked), this is a one-time "ask once" prompt with no ongoing
/// re-check: there's nothing to re-check against.
class AutostartService {
  AutostartService._();
  static final AutostartService instance = AutostartService._();

  static const _kAskedKey = 'autostart_prompt_asked_v1';

  // Must match android/app/build.gradle.kts's applicationId — used only as
  // the last-resort fallback destination (the generic per-app settings
  // page) when the manufacturer-specific intent below doesn't resolve.
  static const _packageName = 'com.example.pulsewatch_app';

  // Manufacturer (DeviceInfoPlugin's lowercase value) -> the settings
  // screen most ROM versions from that OEM use for autostart/protected-
  // apps permission. Sourced from https://dontkillmyapp.com, the same
  // table several open-source Flutter autostart-permission packages draw
  // from. These are undocumented, OEM-internal component names, not a
  // stable public API — wrong or missing on some ROM version is expected
  // and not a bug, which is why [openSettings] always falls back to the
  // generic app-info screen instead of failing silently.
  static const Map<String, ({String package, String componentName})> _targets = {
    'xiaomi': (
      package: 'com.miui.securitycenter',
      componentName: 'com.miui.permcenter.autostart.AutoStartManagementActivity',
    ),
    'redmi': (
      package: 'com.miui.securitycenter',
      componentName: 'com.miui.permcenter.autostart.AutoStartManagementActivity',
    ),
    'poco': (
      package: 'com.miui.securitycenter',
      componentName: 'com.miui.permcenter.autostart.AutoStartManagementActivity',
    ),
    'oppo': (
      package: 'com.coloros.safecenter',
      componentName: 'com.coloros.safecenter.permission.startup.StartupAppListActivity',
    ),
    'realme': (
      package: 'com.coloros.safecenter',
      componentName: 'com.coloros.safecenter.permission.startup.StartupAppListActivity',
    ),
    'vivo': (
      package: 'com.vivo.permissionmanager',
      componentName: 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
    ),
    'iqoo': (
      package: 'com.vivo.permissionmanager',
      componentName: 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity',
    ),
    'huawei': (
      package: 'com.huawei.systemmanager',
      componentName: 'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    ),
    'honor': (
      package: 'com.huawei.systemmanager',
      componentName: 'com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity',
    ),
    'oneplus': (
      package: 'com.oneplus.security',
      componentName: 'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity',
    ),
    'asus': (
      package: 'com.asus.mobilemanager',
      componentName: 'com.asus.mobilemanager.autostart.AutoStartActivity',
    ),
  };

  /// True once, the first time this is asked on a phone from one of the
  /// [_targets] manufacturers — never again after that, regardless of the
  /// answer (there's no way to detect the setting being turned back off
  /// later, unlike battery exemption, so re-nagging would just be a guess).
  Future<bool> needsAutostartPrompt() async {
    if (!Platform.isAndroid) return false;
    if (await _hasAsked()) return false;
    return await _targetForThisDevice() != null;
  }

  Future<void> markAsked() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAskedKey, true);
  }

  Future<bool> _hasAsked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAskedKey) ?? false;
  }

  Future<({String package, String componentName})?> _targetForThisDevice() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return _targets[info.manufacturer.toLowerCase()];
    } catch (_) {
      return null;
    }
  }

  /// Opens the manufacturer-specific autostart settings screen, falling
  /// back to the generic per-app settings page if the specific one isn't
  /// available on this ROM version.
  Future<void> openSettings() async {
    if (!Platform.isAndroid) return;

    final target = await _targetForThisDevice();
    if (target != null) {
      try {
        await AndroidIntent(
          action: 'android.intent.action.MAIN',
          package: target.package,
          componentName: target.componentName,
        ).launch();
        return;
      } catch (_) {
        // Falls through to the generic settings page below — expected on
        // some ROM versions, see _targets' doc comment.
      }
    }
    await _openAppInfoSettings();
  }

  Future<void> _openAppInfoSettings() async {
    try {
      const intent = AndroidIntent(
        action: 'android.settings.APPLICATION_DETAILS_SETTINGS',
        data: 'package:$_packageName',
      );
      await intent.launch();
    } catch (_) {
      // Nothing more we can do from here — the user can find Settings >
      // Apps themselves at this point.
    }
  }
}
