import 'package:flutter/material.dart';

class AppColors {
  // Main backgrounds
  static const Color background = Color(0xFFFAF8F5); // Warm off-white
  static const Color cardBackground = Color(0xFFFFFFFF); // White

  // Primary accents
  static const Color primaryGreen = Color(0xFF7CB686); // Sage green
  static const Color secondaryCoral = Color(0xFFE8A598); // Soft coral

  // Text colors
  static const Color textPrimary = Color(0xFF2D3142); // Dark gray
  static const Color textSecondary = Color(0xFF6B7280); // Medium gray

  // Status colors
  static const Color success = Color(0xFF4CAF50); // Green
  static const Color warning = Color(0xFFF59E0B); // Amber
  static const Color error = Color(0xFFEF5350); // Soft red
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: ColorScheme.light(
        primary: AppColors.primaryGreen,
        secondary: AppColors.secondaryCoral,
        surface: AppColors.cardBackground,
        error: AppColors.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.bold,
        ),
        headlineMedium: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
        ),
        bodyMedium: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 14,
        ),
      ),
    );
  }
}