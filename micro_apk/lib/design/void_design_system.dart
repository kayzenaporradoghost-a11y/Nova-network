import 'package:flutter/material.dart';

abstract final class VoidDesignSystem {
  static final ValueNotifier<String> appName = ValueNotifier<String>('NET work');
  static final ValueNotifier<String> appStyle = ValueNotifier<String>('normal');
  static const neon = Color(0xFFEAF2FF);
  static final ValueNotifier<Color> accent = ValueNotifier<Color>(neon);
  static final ValueNotifier<String> skin = ValueNotifier<String>('void');
  static final ValueNotifier<bool> motion = ValueNotifier<bool>(true);
  static const background = Color(0xFF080808);
  static const panel = Color(0xFF101010);
  static const raised = Color(0xFF171717);
  static const line = Color(0xFF292929);
  static const text = Color(0xFFF3F3F3);
  static const muted = Color(0xFF858585);

  static ThemeData get theme {
    final accentColor = accent.value;
    final bg = skin.value == 'graphite' ? const Color(0xFF0E0F11) : skin.value == 'red' ? const Color(0xFF030101) : Colors.black;
    final surface = skin.value == 'graphite' ? const Color(0xFF151515) : panel;
    final scheme = ColorScheme.dark(
      primary: accentColor, onPrimary: Colors.white,
      secondary: const Color(0xFFBDBDBD), onSecondary: bg,
      surface: surface, onSurface: text,
      error: neon, onError: bg,
      outline: line, onSurfaceVariant: muted,
    );
    return ThemeData(
      useMaterial3: true, brightness: Brightness.dark, colorScheme: scheme,
      scaffoldBackgroundColor: bg, canvasColor: bg,
      dividerColor: line, splashColor: accentColor.withValues(alpha: .08),
      appBarTheme: const AppBarTheme(
        backgroundColor: background, foregroundColor: text, elevation: 0,
        surfaceTintColor: Colors.transparent, centerTitle: false,
        titleTextStyle: TextStyle(color: text, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1.4),
      ),
      cardTheme: const CardThemeData(color: panel, elevation: 0, margin: EdgeInsets.zero),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: raised, hintStyle: const TextStyle(color: muted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: accentColor, width: 1.3)),
      ),
      textTheme: const TextTheme(
        headlineMedium: TextStyle(color: text, fontWeight: FontWeight.w800, letterSpacing: -.7),
        titleLarge: TextStyle(color: text, fontWeight: FontWeight.w700),
        titleMedium: TextStyle(color: text, fontWeight: FontWeight.w700),
        bodyLarge: TextStyle(color: text), bodyMedium: TextStyle(color: text),
        bodySmall: TextStyle(color: muted), labelLarge: TextStyle(color: text, fontWeight: FontWeight.w700),
      ),
      iconTheme: const IconThemeData(color: muted),
      dividerTheme: const DividerThemeData(color: line, thickness: .7),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accentColor, linearTrackColor: line),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: raised),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
        backgroundColor: accentColor, foregroundColor: Colors.white, elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      )),
      outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
        foregroundColor: text, side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      )),
      textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: muted)),
      sliderTheme: SliderThemeData(activeTrackColor: accentColor, thumbColor: accentColor, inactiveTrackColor: line),
    );
  }
}
