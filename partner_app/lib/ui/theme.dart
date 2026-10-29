import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// FITKEY member-app palette: clean light surfaces, an energetic ember accent,
/// and the brand's electric lime reserved for the FitKey Pass.
class AppColors {
  static const primary = Color(0xFFFF5A36);
  static const primaryDeep = Color(0xFFE5431F);
  static const primarySoft = Color(0xFFFFEEE9);

  static const ink = Color(0xFF1A1B25);
  static const text = Color(0xFF1A1B25);
  static const text2 = Color(0xFF5C5F6E);
  static const text3 = Color(0xFF9396A5);

  static const bg = Color(0xFFF5F6FA);
  static const surface = Colors.white;
  static const surfaceAlt = Color(0xFFF0F1F5);
  static const line = Color(0xFFE9EAF0);

  static const green = Color(0xFF1BA672);
  static const greenSoft = Color(0xFFE6F6EF);
  static const amber = Color(0xFFFFA41B);
  static const amberSoft = Color(0xFFFFF4E0);
  static const blue = Color(0xFF3D7BFF);
  static const blueSoft = Color(0xFFEAF1FF);
  static const purple = Color(0xFF7C5CFF);
  static const purpleSoft = Color(0xFFF0ECFF);
  static const pink = Color(0xFFFF4F9A);
  static const pinkSoft = Color(0xFFFFEBF3);
  static const teal = Color(0xFF14B8A6);
  static const tealSoft = Color(0xFFE3F8F5);
  static const red = Color(0xFFE53950);
  static const redSoft = Color(0xFFFDECEE);

  /// Brand heritage colour, used on dark "pass" surfaces only.
  static const lime = Color(0xFFC8F31D);

  static const mansiGradient = LinearGradient(
    colors: [Color(0xFF7C5CFF), Color(0xFFFF4F9A), Color(0xFFFF8A3D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const primaryGradient = LinearGradient(
    colors: [Color(0xFFFF7A45), Color(0xFFFF4B2B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const passGradient = LinearGradient(
    colors: [Color(0xFF23252F), Color(0xFF111218)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class AppShadows {
  static const card = [
    BoxShadow(color: Color(0x0F1A1B25), blurRadius: 18, offset: Offset(0, 6)),
    BoxShadow(color: Color(0x081A1B25), blurRadius: 3, offset: Offset(0, 1)),
  ];
  static const soft = [BoxShadow(color: Color(0x0A1A1B25), blurRadius: 10, offset: Offset(0, 3))];
  static List<BoxShadow> glow(Color c) => [
        BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 20, offset: const Offset(0, 8)),
      ];
}

const kFont = 'PlusJakartaSans';

ThemeData buildAppTheme() {
  const scheme = ColorScheme.light(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    secondary: AppColors.ink,
    onSecondary: Colors.white,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    surfaceContainerHighest: AppColors.surfaceAlt,
    outline: AppColors.line,
    outlineVariant: AppColors.line,
    error: AppColors.red,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: kFont, brightness: Brightness.light);
  final t = base.textTheme.apply(bodyColor: AppColors.text, displayColor: AppColors.text, fontFamily: kFont);

  OutlineInputBorder border(Color c, [double w = 1]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    splashFactory: InkSparkle.splashFactory,
    textTheme: t.copyWith(
      displaySmall: t.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.8),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.6),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3, fontSize: 20),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w700, fontSize: 16),
      titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      bodyLarge: t.bodyLarge?.copyWith(fontSize: 15, height: 1.45),
      bodyMedium: t.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: t.bodySmall?.copyWith(color: AppColors.text2, fontSize: 12.5),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      shadowColor: AppColors.line,
      centerTitle: false,
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
      ),
      titleTextStyle: TextStyle(
          fontFamily: kFont, fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.text, letterSpacing: -0.3),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.line,
        disabledForegroundColor: AppColors.text3,
        minimumSize: const Size.fromHeight(54),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: kFont, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 0.1),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        foregroundColor: AppColors.text,
        side: const BorderSide(color: AppColors.line, width: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: kFont, fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: border(AppColors.line),
      enabledBorder: border(AppColors.line),
      focusedBorder: border(AppColors.primary, 1.6),
      errorBorder: border(AppColors.red),
      focusedErrorBorder: border(AppColors.red, 1.6),
      hintStyle: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w500),
      labelStyle: const TextStyle(color: AppColors.text2, fontWeight: FontWeight.w500),
      floatingLabelStyle: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700),
      prefixIconColor: AppColors.text3,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surface,
      selectedColor: AppColors.primarySoft,
      side: const BorderSide(color: AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
      labelStyle: const TextStyle(fontFamily: kFont, fontWeight: FontWeight.w600, color: AppColors.text, fontSize: 13),
      showCheckmark: false,
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.text2,
      indicatorColor: AppColors.primary,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: AppColors.line,
      labelStyle: TextStyle(fontFamily: kFont, fontWeight: FontWeight.w800, fontSize: 14),
      unselectedLabelStyle: TextStyle(fontFamily: kFont, fontWeight: FontWeight.w600, fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.ink,
      contentTextStyle: const TextStyle(fontFamily: kFont, color: Colors.white, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: AppColors.line,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: const TextStyle(fontFamily: kFont, fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.text),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, space: 1, thickness: 1),
    sliderTheme: const SliderThemeData(
      activeTrackColor: AppColors.primary,
      thumbColor: AppColors.primary,
      inactiveTrackColor: AppColors.line,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.primary, linearTrackColor: AppColors.line),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.green : null),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.primary : AppColors.text3),
    ),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.text2, contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
