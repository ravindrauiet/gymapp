import 'package:flutter/material.dart';

/// FITKEY brand palette: deep charcoal with an electric-lime "key" accent.
class FkColors {
  static const background = Color(0xFF0E1013);
  static const surface = Color(0xFF171A1F);
  static const surfaceHigh = Color(0xFF20242B);
  static const outline = Color(0xFF2C313A);
  static const lime = Color(0xFFC8F31D);
  static const orange = Color(0xFFFF6B35);
  static const sky = Color(0xFF4CC9F0);
  static const violet = Color(0xFF9B7BFF);
  static const textPrimary = Color(0xFFF4F6F8);
  static const textSecondary = Color(0xFF9AA3AF);
  static const danger = Color(0xFFFF5470);
  static const success = Color(0xFF3DDC97);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: FkColors.lime,
    onPrimary: Colors.black,
    secondary: FkColors.orange,
    onSecondary: Colors.black,
    surface: FkColors.surface,
    onSurface: FkColors.textPrimary,
    surfaceContainerHighest: FkColors.surfaceHigh,
    outline: FkColors.outline,
    error: FkColors.danger,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  final text = base.textTheme.apply(bodyColor: FkColors.textPrimary, displayColor: FkColors.textPrimary);

  return base.copyWith(
    scaffoldBackgroundColor: FkColors.background,
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: FkColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: FkColors.textPrimary),
    ),
    cardTheme: CardThemeData(
      color: FkColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: FkColors.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: FkColors.textPrimary,
        side: const BorderSide(color: FkColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FkColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: FkColors.outline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: FkColors.outline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: FkColors.lime, width: 1.5)),
      hintStyle: const TextStyle(color: FkColors.textSecondary),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: FkColors.surface,
      selectedColor: FkColors.lime,
      side: const BorderSide(color: FkColors.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: FkColors.surface,
      indicatorColor: FkColors.lime.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? FkColors.lime : FkColors.textSecondary),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected) ? FkColors.lime : FkColors.textSecondary,
        ),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: FkColors.lime,
      unselectedLabelColor: FkColors.textSecondary,
      indicatorColor: FkColors.lime,
      dividerColor: FkColors.outline,
      labelStyle: TextStyle(fontWeight: FontWeight.w700),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: FkColors.surface,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    dividerTheme: const DividerThemeData(color: FkColors.outline, space: 1),
  );
}
