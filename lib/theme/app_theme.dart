import 'package:flutter/material.dart';

/// Tema escuro ouro — réplica fiel do ui/theme.qss do desktop:
/// bg #0f1117, painéis #1a1d27 / #151821, ouro #d4a84b, texto #f2f4f8.
class AppTheme {
  static const bg = Color(0xFF0F1117);
  static const panel = Color(0xFF1A1D27);
  static const sidebar = Color(0xFF151821);
  static const card = Color(0xFF1A1E29);
  static const border = Color(0xFF232936);
  static const borderLight = Color(0xFF3A4253);
  static const gold = Color(0xFFD4A84B);
  static const goldSoft = Color(0xFF292F3D);
  static const text = Color(0xFFF2F4F8);
  static const textMuted = Color(0xFFA6ADBD);
  static const textFaint = Color(0xFF5C6474);
  static const hint = Color(0xFF7B8394);

  static ThemeData dark() {
    final scheme = const ColorScheme.dark(
      primary: gold,
      secondary: gold,
      surface: panel,
      error: Color(0xFFE57373),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: sidebar,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: text),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: sidebar,
        indicatorColor: goldSoft,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(color: textMuted, fontSize: 12),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        hintStyle: const TextStyle(color: hint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: gold),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: gold,
          foregroundColor: const Color(0xFF14161D),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: text),
        bodyLarge: TextStyle(color: text),
        titleLarge: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        titleMedium: TextStyle(color: text, fontWeight: FontWeight.bold),
        labelSmall: TextStyle(color: textFaint, fontWeight: FontWeight.bold),
      ),
      dialogTheme: const DialogThemeData(backgroundColor: panel),
      bottomSheetTheme:
          const BottomSheetThemeData(backgroundColor: panel),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF232936),
        contentTextStyle: const TextStyle(color: text),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: gold),
        ),
        elevation: 8,
      ),
    );
  }
}
