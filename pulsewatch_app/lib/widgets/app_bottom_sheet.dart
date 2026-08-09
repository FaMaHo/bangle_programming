import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Shared visual chrome for every confirmation/prompt sheet in the app —
/// rounded top corners, a drag handle, and consistent padding. Used instead
/// of centered AlertDialogs so every "are you sure / do you want to" moment
/// feels like one app, not a mix of popup styles.
class AppBottomSheetChrome extends StatelessWidget {
  final Widget child;

  const AppBottomSheetChrome({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

/// Icon badge used at the top of most prompt sheets — a colored circle
/// around an icon, matching the language already used across the app's
/// cards (watch status, stat tiles, etc).
class AppSheetIconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const AppSheetIconBadge({super.key, required this.icon, required this.color, this.size = 48});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
      child: Icon(icon, color: color, size: size * 0.5),
    );
  }
}

/// A simple icon+title+body prompt with a full-width primary action and a
/// text-link secondary action underneath — the "Accept cookies / Decline
/// cookies" shape, in the app's own palette. Use this for any yes/no
/// decision that doesn't need its own custom state (loading, retry, etc);
/// for those, compose AppBottomSheetChrome directly instead.
Future<bool?> showAppConfirmSheet({
  required BuildContext context,
  required IconData icon,
  required Color iconColor,
  required String title,
  required String body,
  required String primaryLabel,
  String secondaryLabel = 'Not now',
  List<Widget> extra = const [],
  bool primaryIsDestructive = false,
  bool isDismissible = true,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isDismissible: isDismissible,
    backgroundColor: Colors.transparent,
    builder: (context) => AppBottomSheetChrome(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSheetIconBadge(icon: icon, color: iconColor),
          const SizedBox(height: 16),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4)),
          ...extra,
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: primaryIsDestructive
                  ? FilledButton.styleFrom(backgroundColor: AppColors.error)
                  : null,
              child: Text(primaryLabel),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(secondaryLabel),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A muted icon+text hint line — used for the recurring "change this
/// anytime in Settings" / "anonymized, no name or device ID" footnotes
/// under a prompt's body text.
class AppSheetHint extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const AppSheetHint({super.key, required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
