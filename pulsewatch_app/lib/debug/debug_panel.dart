import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../services/ble_service.dart';
import '../theme/app_theme.dart';
import 'debug_data_seeder.dart';

/// Debug-only control panel for driving the app through every connection,
/// sync, and data state it can produce — used to preview screens on the
/// Android emulator, which has no real watch to connect to. [show] is a
/// no-op in release builds (see kDebugMode), so this can never surface on a
/// shipped build.
class DebugPanel extends StatefulWidget {
  const DebugPanel({super.key});

  static void show(BuildContext context) {
    if (!kDebugMode) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const DebugPanel(),
    );
  }

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String doneLabel) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(doneLabel), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = BleService();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.cardBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Preview Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                'Debug build only — simulates watch & data states',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: LinearProgressIndicator(color: AppColors.primaryGreen),
              ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _section('Connection'),
                  _button(
                    'Connect — Bangle.js',
                    () => ble.debugSimulateConnect(deviceType: DeviceType.bangleJS),
                  ),
                  _button(
                    'Connect — T-Watch',
                    () => ble.debugSimulateConnect(deviceType: DeviceType.tWatch),
                  ),
                  _button('Disconnect', () => ble.debugSimulateDisconnect()),
                  _button(
                    'Reconnecting…',
                    () => ble.debugSimulateReconnecting(label: 'Bangle.js 2'),
                  ),
                  _section('Sync'),
                  _button(
                    'Play sync progress (3 files)',
                    () => ble.debugRunSyncProgressDemo(),
                  ),
                  _button(
                    'Sync failure',
                    () => ble.debugSimulateSyncFailure(
                      "Timed out waiting for pw${DateTime.now().millisecondsSinceEpoch}.csv",
                    ),
                    destructive: true,
                  ),
                  _section('Session data'),
                  _button(
                    'Seed 2h — just started',
                    () => DebugDataSeeder.seed(coverage: const Duration(hours: 2)),
                  ),
                  _button(
                    'Seed 30h — in progress (+gap)',
                    () => DebugDataSeeder.seed(
                      coverage: const Duration(hours: 30),
                      includeGap: true,
                    ),
                  ),
                  _button(
                    'Seed 48h — complete, triggers report',
                    () => DebugDataSeeder.seed(coverage: const Duration(hours: 48)),
                  ),
                  _button(
                    'Clear all data',
                    () => DebugDataSeeder.clearAll(),
                    destructive: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.textSecondary),
        ),
      );

  Widget _button(String label, Future<void> Function() action, {bool destructive = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _busy ? null : () => _run(action, label),
            style: OutlinedButton.styleFrom(
              foregroundColor: destructive ? AppColors.error : AppColors.textPrimary,
              side: BorderSide(color: destructive ? AppColors.error.withOpacity(0.4) : Colors.grey.shade300),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(label),
          ),
        ),
      );
}
