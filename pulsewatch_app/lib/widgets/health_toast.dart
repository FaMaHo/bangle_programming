import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// How urgent a HealthIssue is — controls the toast's color only. Both are
/// non-blocking; there's no "critical" tier that interrupts the user, since
/// none of these conditions need an immediate decision the way the
/// confirm-sheet prompts elsewhere in the app do.
enum ToastSeverity { warning, error }

/// A single thing worth telling the user about right now — a watch that
/// dropped, background running getting disabled, etc. [id] is stable
/// per *kind* of issue (not per occurrence) — it's what the cooldown and
/// dismiss tracking in main.dart key off of.
class HealthIssue {
  final String id;
  final ToastSeverity severity;
  final IconData icon;
  final String title;
  final String message;
  // Optional — e.g. re-opening the battery-exemption request, or jumping
  // to the Device tab. The dismiss (x) button always works independently
  // of this.
  final VoidCallback? onTap;

  const HealthIssue({
    required this.id,
    required this.severity,
    required this.icon,
    required this.title,
    required this.message,
    this.onTap,
  });
}

/// Floating, dismissible banner for the current HealthIssue (if any) —
/// sits over whatever tab is active rather than living on one screen, since
/// the conditions it reports (BLE, background running) aren't tied to any
/// single tab. Renders nothing when [issue] is null.
class HealthToastBanner extends StatelessWidget {
  final HealthIssue? issue;
  final VoidCallback onDismiss;

  const HealthToastBanner({super.key, required this.issue, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, -0.15), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: issue == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : _Toast(key: ValueKey(issue!.id), issue: issue!, onDismiss: onDismiss),
    );
  }
}

class _Toast extends StatelessWidget {
  final HealthIssue issue;
  final VoidCallback onDismiss;

  const _Toast({super.key, required this.issue, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final color = issue.severity == ToastSeverity.error ? AppColors.error : AppColors.warning;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: issue.onTap,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(issue.icon, color: color, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            issue.title,
                            style: TextStyle(color: AppColors.textPrimary, fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            issue.message,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, color: AppColors.textSecondary, size: 17),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
