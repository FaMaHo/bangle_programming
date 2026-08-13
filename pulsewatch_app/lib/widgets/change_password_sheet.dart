import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import 'app_bottom_sheet.dart';

/// Shows the sheet and returns once it's closed — the sheet reports its
/// own success via a SnackBar before popping, so there's nothing for the
/// caller to do with the result beyond knowing it finished.
Future<void> showChangePasswordSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const _ChangePasswordSheetBody(),
  );
}

class _ChangePasswordSheetBody extends StatefulWidget {
  const _ChangePasswordSheetBody();

  @override
  State<_ChangePasswordSheetBody> createState() => _ChangePasswordSheetBodyState();
}

class _ChangePasswordSheetBodyState extends State<_ChangePasswordSheetBody> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _obscureCurrent = true;
  bool _obscureNew = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _currentController.text;
    final next = _newController.text;
    final confirm = _confirmController.text;

    if (current.isEmpty || next.isEmpty) {
      setState(() => _error = 'Fill in both password fields.');
      return;
    }
    if (next.length < 8) {
      setState(() => _error = 'New password must be at least 8 characters.');
      return;
    }
    if (next != confirm) {
      setState(() => _error = 'New passwords don\'t match.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await AuthService.instance.changePassword(
      currentPassword: current,
      newPassword: next,
    );

    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed.'), duration: Duration(seconds: 2)),
      );
    } else {
      setState(() {
        _busy = false;
        _error = result.error ?? 'Something went wrong.';
      });
    }
  }

  InputDecoration _fieldDecoration(String label, bool obscured, VoidCallback toggleObscure) {
    return InputDecoration(
      labelText: label,
      suffixIcon: IconButton(
        icon: Icon(obscured ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
        onPressed: toggleObscure,
      ),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // AppBottomSheetChrome already pads for the keyboard itself (see its
    // own viewInsets.bottom usage) — adding another layer of the same
    // padding here double-counted it, shrinking the space actually left
    // for content below the keyboard until it overflowed. The
    // SingleChildScrollView is a second line of defense for shorter
    // screens where even the correct amount still leaves this form (icon +
    // title + 3 fields + 2 buttons) taller than what's left above the
    // keyboard.
    return AppBottomSheetChrome(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSheetIconBadge(icon: Icons.lock_outline_rounded, color: AppColors.primaryGreen),
            const SizedBox(height: 16),
            const Text(
              'Change password',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _currentController,
              obscureText: _obscureCurrent,
              decoration: _fieldDecoration(
                'Current password',
                _obscureCurrent,
                () => setState(() => _obscureCurrent = !_obscureCurrent),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _newController,
              obscureText: _obscureNew,
              decoration: _fieldDecoration(
                'New password',
                _obscureNew,
                () => setState(() => _obscureNew = !_obscureNew),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _confirmController,
              obscureText: _obscureNew,
              decoration: _fieldDecoration('Confirm new password', _obscureNew, () {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.error, fontSize: 12.5)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Change password'),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

