import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'server_service.dart';

/// Handles account creation (via a researcher-issued enrollment code),
/// login, and token storage/refresh. Tokens live in secure, encrypted
/// storage (Keychain on iOS, Keystore-backed on Android) — never in
/// plain SharedPreferences.
class AuthService {
  static final AuthService instance = AuthService._init();
  AuthService._init();

  static const _storage = FlutterSecureStorage();

  static const _kAccessToken = 'access_token';
  static const _kRefreshToken = 'refresh_token';
  static const _kPatientId = 'patient_id';
  static const _kRole = 'role';
  static const _kUsername = 'username';

  Future<bool> isLoggedIn() async {
    return (await _storage.read(key: _kRefreshToken)) != null;
  }

  Future<String?> getAccessToken() => _storage.read(key: _kAccessToken);

  Future<String?> getPatientId() => _storage.read(key: _kPatientId);

  Future<String?> getRole() => _storage.read(key: _kRole);

  Future<String?> getUsername() => _storage.read(key: _kUsername);

  Future<Map<String, String>> authHeader() async {
    final token = await getAccessToken();
    return token == null ? {} : {'Authorization': 'Bearer $token'};
  }

  Future<AuthResult> claim({
    required String code,
    required String username,
    required String password,
  }) async {
    if (password.length < 8) {
      return AuthResult.failure('Password must be at least 8 characters');
    }
    return _authRequest('/auth/claim', {
      'code': code.trim(),
      'username': username.trim(),
      'password': password,
    });
  }

  Future<AuthResult> login({
    required String username,
    required String password,
  }) async {
    return _authRequest('/auth/login', {
      'username': username.trim(),
      'password': password,
    });
  }

  Future<AuthResult> _authRequest(String path, Map<String, String> body) async {
    try {
      final serverUrl = await ServerService.instance.getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) {
        return AuthResult.failure('Server URL not configured.');
      }

      final response = await http
          .post(
            Uri.parse('$serverUrl$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200 || response.statusCode == 201) {
        await _storage.write(key: _kAccessToken, value: json['access_token'] as String);
        await _storage.write(key: _kRefreshToken, value: json['refresh_token'] as String);
        await _storage.write(key: _kPatientId, value: json['patient_id'] as String);
        await _storage.write(key: _kRole, value: json['role'] as String);
        await _storage.write(key: _kUsername, value: body['username']);
        return AuthResult.success(
          patientId: json['patient_id'] as String,
          role: json['role'] as String,
        );
      }

      return AuthResult.failure((json['error'] as String?) ?? 'Something went wrong.');
    } catch (_) {
      return AuthResult.failure('Could not reach the server. Check your connection.');
    }
  }

  /// Refreshes the access token using the stored refresh token.
  /// Returns the new access token, or null if the refresh token is
  /// missing/expired — in which case stored auth state is cleared and
  /// the caller should route back to the login screen.
  Future<String?> refreshAccessToken() async {
    final refreshToken = await _storage.read(key: _kRefreshToken);
    if (refreshToken == null) return null;

    try {
      final serverUrl = await ServerService.instance.getServerUrl();
      final response = await http.post(
        Uri.parse('$serverUrl/auth/refresh'),
        headers: {'Authorization': 'Bearer $refreshToken'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        await logout();
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final newAccessToken = json['access_token'] as String;
      await _storage.write(key: _kAccessToken, value: newAccessToken);
      return newAccessToken;
    } catch (_) {
      // Network failure isn't the same as an invalid token — don't log
      // the user out just because the request timed out.
      return null;
    }
  }

  Future<void> logout() async {
    await _storage.deleteAll();
  }
}

class AuthResult {
  final bool success;
  final String? error;
  final String? patientId;
  final String? role;

  AuthResult._(this.success, this.error, this.patientId, this.role);

  factory AuthResult.success({required String patientId, required String role}) =>
      AuthResult._(true, null, patientId, role);

  factory AuthResult.failure(String error) => AuthResult._(false, error, null, null);
}
