import 'package:flutter/material.dart';

/// TyrannoFi color palette (from the original web UI).
class TF {
  static const bg = Color(0xFF1A1008);
  static const surface = Color(0xFF241A0E);
  static const surface2 = Color(0xFF2E2115);
  static const border = Color(0xFF3A2A18);
  static const text = Color(0xFFF0E4D4);
  static const text2 = Color(0xFF8B5E3C);
  static const accent = Color(0xFFC4956A);
  static const accent2 = Color(0xFFD4BFA5);
  static const cream = Color(0xFFE8D5BC);
  static const danger = Color(0xFFCF6679);
  static const ok = Color(0xFF7FB069);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: TF.accent,
    onPrimary: TF.bg,
    secondary: TF.accent2,
    onSecondary: TF.bg,
    surface: TF.surface,
    onSurface: TF.text,
    error: TF.danger,
    onError: TF.bg,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: TF.bg,
    canvasColor: TF.bg,
    dividerColor: TF.border,
    fontFamily: 'sans-serif',
    appBarTheme: const AppBarTheme(
      backgroundColor: TF.bg,
      foregroundColor: TF.accent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: TF.accent,
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: 2,
      ),
    ),
    cardTheme: CardThemeData(
      color: TF.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: TF.border),
      ),
      margin: const EdgeInsets.symmetric(vertical: 5),
    ),
    listTileTheme: const ListTileThemeData(iconColor: TF.accent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: TF.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TF.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TF.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: TF.accent),
      ),
      labelStyle: const TextStyle(color: TF.text2),
      hintStyle: const TextStyle(color: TF.text2),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: TF.accent,
        foregroundColor: TF.bg,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: TF.accent,
        side: const BorderSide(color: TF.border),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: TF.accent),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: TF.surface2,
      contentTextStyle: TextStyle(color: TF.text),
      behavior: SnackBarBehavior.floating,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: TF.accent,
      linearTrackColor: TF.surface2,
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: TF.surface2,
      side: BorderSide(color: TF.border),
      labelStyle: TextStyle(color: TF.accent2, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: TF.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: TF.border),
      ),
    ),
  );
}
