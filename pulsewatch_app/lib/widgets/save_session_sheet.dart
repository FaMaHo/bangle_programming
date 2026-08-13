import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';

enum SaveSessionAction { startNew, stop }

/// Result of [showSaveSessionSheet] — null means the user backed out.
class SaveSessionChoice {
  final SaveSessionAction action;
  final bool deleteRawData;
  const SaveSessionChoice({required this.action, required this.deleteRawData});
}

/// Confirms archiving the current report, then either starting a fresh 48h
/// session right away or stopping until the user explicitly starts one
/// later. Needs its own sheet rather than showAppConfirmSheet: the opt-in
/// checkbox requires local state a plain static sheet can't hold, and two
/// distinct primary actions (not just confirm/cancel) both need to come
/// back out alongside it.
Future<SaveSessionChoice?> showSaveSessionSheet(BuildContext context) {
  return showModalBottomSheet<SaveSessionChoice>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (context) => const _SaveSessionSheetBody(),
  );
}

class _SaveSessionSheetBody extends StatefulWidget {
  const _SaveSessionSheetBody();

  @override
  State<_SaveSessionSheetBody> createState() => _SaveSessionSheetBodyState();
}

class _SaveSessionSheetBodyState extends State<_SaveSessionSheetBody> {
  bool _deleteRawData = false;

  @override
  Widget build(BuildContext context) {
    return AppBottomSheetChrome(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppSheetIconBadge(icon: Icons.archive_outlined, color: AppColors.primaryGreen),
          const SizedBox(height: 16),
          const Text(
            'Save this report',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          const Text(
            'It\'ll be saved to your profile in Settings either way. Choose what happens next.',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => _deleteRawData = !_deleteRawData),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _deleteRawData,
                    onChanged: (v) => setState(() => _deleteRawData = v ?? false),
                    activeColor: AppColors.primaryGreen,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Also delete this session\'s raw heart-rate readings to free up space. '
                        'The saved report itself is kept either way.',
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(
                SaveSessionChoice(action: SaveSessionAction.startNew, deleteRawData: _deleteRawData),
              ),
              child: const Text('Save & start new session'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(
                SaveSessionChoice(action: SaveSessionAction.stop, deleteRawData: _deleteRawData),
              ),
              child: const Text('Save & stop for now'),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ),
        ],
      ),
    );
  }
}
