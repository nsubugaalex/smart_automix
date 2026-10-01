import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// App-wide theme and formatting helpers for the Uganda deployment:
/// colours drawn from the national flag used as brand chrome (app bar,
/// nav bar, FAB), a separate set of semantic status colours used for
/// machine/circuit state so "running" is never confused with "danger",
/// and a UGX currency formatter (UEDCL bills are in Uganda Shillings).
class UgandaTheme {
  UgandaTheme._();

  // Brand colours (flag) — used for chrome, not for machine state.
  static const Color black = Color(0xFF000000);
  static const Color yellow = Color(0xFFFCDC04);
  static const Color red = Color(0xFFD90000);

  // Semantic status colours — used consistently for machine/circuit state
  // so colour always means the same thing across the app.
  static const Color running = Color(0xFF2E7D32); // a machine is on
  static const Color off = Color(0xFF9E9E9E); // a machine is off
  static const Color warning = Color(0xFFF57C00); // approaching a limit
  static const Color danger = red; // overloaded / tripped / error

  static const _radius = 12.0;

  static ThemeData get themeData => _buildTheme(Brightness.light);

  static ThemeData get darkThemeData => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: isDark ? yellow : black,
      brightness: brightness,
      primary: isDark ? yellow : black,
      secondary: yellow,
      tertiary: red,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF161616) : black,
        foregroundColor: yellow,
        elevation: 0,
        scrolledUnderElevation: 2,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: yellow,
        foregroundColor: black,
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: yellow.withAlpha(isDark ? 60 : 90),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.bold
                : FontWeight.normal,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? running : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? running.withAlpha(140)
              : null,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: isDark ? 0 : 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(_radius)),
        filled: true,
        fillColor: isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(5),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
      ),
    );
  }

  static final NumberFormat _ugxFormat = NumberFormat.currency(
    locale: 'en_UG',
    symbol: 'UGX ',
    decimalDigits: 0,
  );

  /// Format an amount as Ugandan Shillings, e.g. "UGX 12,500".
  static String formatUgx(num amount) => _ugxFormat.format(amount);
}
