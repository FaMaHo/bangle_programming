import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/auth_service.dart';
import 'login_screen.dart';

/// First-time setup: turn a one-time enrollment code (given by the
/// researcher) into a real account by choosing a username and password.
class EnrollScreen extends StatefulWidget {
  final VoidCallback onEnrolled;

  const EnrollScreen({super.key, required this.onEnrolled});

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSubmitting = false;
  String? _errorText;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _codeController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final result = await AuthService.instance.claim(
      code: _codeController.text,
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (result.success) {
      widget.onEnrolled();
    } else {
      setState(() => _errorText = result.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primaryGreen.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.key_rounded, color: AppColors.primaryGreen, size: 28),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Set up your\naccount',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Enter the code your researcher gave you,\nthen choose a username and password.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 32),

                if (_errorText != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.error.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.error.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline_rounded, color: AppColors.error, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(_errorText!,
                              style: const TextStyle(color: AppColors.error, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                _buildLabel('Enrollment code'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(8),
                  ],
                  style: const TextStyle(letterSpacing: 3, fontWeight: FontWeight.w600),
                  decoration: _inputDecoration(hint: 'ABCD1234', icon: Icons.qr_code_rounded),
                  validator: (v) =>
                      (v == null || v.trim().length < 6) ? 'Enter the 8-character code' : null,
                ),
                const SizedBox(height: 20),

                _buildLabel('Choose a username'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _usernameController,
                  decoration: _inputDecoration(hint: 'e.g. maria_p', icon: Icons.person_outline_rounded),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Enter a username' : null,
                ),
                const SizedBox(height: 20),

                _buildLabel('Choose a password'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: _inputDecoration(
                    hint: 'At least 8 characters',
                    icon: Icons.lock_outline_rounded,
                    suffix: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        color: AppColors.textSecondary,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) => (v == null || v.length < 8)
                      ? 'Password must be at least 8 characters'
                      : null,
                ),
                const SizedBox(height: 20),

                _buildLabel('Confirm password'),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _confirmController,
                  obscureText: _obscurePassword,
                  decoration: _inputDecoration(hint: 'Re-enter password', icon: Icons.lock_outline_rounded),
                  validator: (v) =>
                      (v != _passwordController.text) ? 'Passwords do not match' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),

                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Text('Create account',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),

                const SizedBox(height: 20),
                Center(
                  child: TextButton(
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            Navigator.of(context).pushReplacement(
                              MaterialPageRoute(
                                builder: (_) => LoginScreen(onLoggedIn: widget.onEnrolled),
                              ),
                            );
                          },
                    child: const Text(
                      'I already have an account',
                      style: TextStyle(color: AppColors.primaryGreen, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: AppColors.textSecondary.withOpacity(0.5)),
      prefixIcon: Icon(icon, color: AppColors.textSecondary, size: 20),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.cardBackground,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.grey.withOpacity(0.2)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primaryGreen, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.error, width: 1.5),
      ),
    );
  }
}
