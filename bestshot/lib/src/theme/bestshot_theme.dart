import 'package:flutter/material.dart';

/// BestShot プロフェッショナルモード デザイン仕様書 (v1.0.0) 準拠テーマ
class BestShotTheme {
  // --- 1. カラーパレット ---
  /// 背景（プライマリ）: ほぼ黒ダークグレー #0D0D0D
  static const Color backgroundPrimary = Color(0xFF0D0D0D);

  /// サーフェス（カード・シート）: チャコールグレー #1C1C1E
  static const Color surfaceColor = Color(0xFF1C1C1E);

  /// ディバイダー・ボーダー: ダークセパレーター #2C2C2E
  static const Color dividerColor = Color(0xFF2C2C2E);

  /// ホバー/フォーカス: ライトグレーオーバーレイ #3A3A3C
  static const Color hoverColor = Color(0xFF3A3A3C);

  /// アクセント（実行・選択）: インテリジェンスブルー #3A86FF
  static const Color accentBlue = Color(0xFF3A86FF);

  /// アクセント（警告・危険・削除）: 警告レッド #FF006E
  static const Color accentRed = Color(0xFFFF006E);

  /// アクセント（推奨・判定・高スコア）: ゴールドイエロー #FFBE0B
  static const Color accentGold = Color(0xFFFFBE0B);

  /// 補助テキスト: ソフトグレー #8A8A8E
  static const Color textSecondary = Color(0xFF8A8A8E);

  /// 成功・完了・フォーカスマスク: グリーンアクセント #00D084
  static const Color accentGreen = Color(0xFF00D084);

  /// プライマリテキスト: ホワイト #FFFFFF
  static const Color textPrimary = Color(0xFFFFFFFF);

  // --- 2. フォント指定 ---
  static const String fontFamily = 'Roboto';
  static const List<String> fallbackFontFamily = [
    'Segoe UI',
    'Roboto',
    'Noto Sans JP',
    'sans-serif',
  ];

  // --- 3. TextTheme 完全定義 ---
  static const TextTheme textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      height: 1.3,
      color: textPrimary,
    ),
    displayMedium: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4,
      height: 1.4,
      color: textPrimary,
    ),
    headlineLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
      height: 1.3,
      color: textPrimary,
    ),
    headlineMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      height: 1.4,
      color: textPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
      height: 1.3,
      color: textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      height: 1.4,
      color: textSecondary,
    ),
    bodyLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.3,
      height: 1.6,
      color: textPrimary,
    ),
    bodyMedium: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.2,
      height: 1.5,
      color: textPrimary,
    ),
    bodySmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.2,
      height: 1.4,
      color: textSecondary,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      height: 1.2,
      color: accentBlue,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4,
      height: 1.2,
      color: textSecondary,
    ),
    labelSmall: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w400,
      letterSpacing: 0.3,
      height: 1.2,
      color: textSecondary,
    ),
  );

  // --- 4. ThemeData 完全定義 ---
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamilyFallback: fallbackFontFamily,
      primaryColor: accentBlue,
      scaffoldBackgroundColor: backgroundPrimary,
      canvasColor: backgroundPrimary,
      cardColor: surfaceColor,
      dividerColor: dividerColor,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      textTheme: textTheme,
      colorScheme: const ColorScheme(
        brightness: Brightness.dark,
        primary: accentBlue,
        onPrimary: textPrimary,
        primaryContainer: Color(0xFF1E3A66),
        onPrimaryContainer: textPrimary,
        secondary: accentGreen,
        onSecondary: backgroundPrimary,
        secondaryContainer: Color(0xFF133827),
        onSecondaryContainer: textPrimary,
        tertiary: accentGold,
        onTertiary: backgroundPrimary,
        error: accentRed,
        onError: textPrimary,
        errorContainer: Color(0xFF4D0020),
        onErrorContainer: textPrimary,
        surface: surfaceColor,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        outline: dividerColor,
        outlineVariant: hoverColor,
      ),
      // フラットデザイン（影・ブラー・過度な丸みの排除）
      cardTheme: CardThemeData(
        color: surfaceColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: dividerColor, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accentBlue,
          foregroundColor: textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accentBlue,
          foregroundColor: textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          elevation: 0,
          side: const BorderSide(color: dividerColor, width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentBlue,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceColor,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: dividerColor, width: 1),
        ),
        titleTextStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: dividerColor, width: 1),
        ),
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: dividerColor, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: dividerColor, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: accentBlue, width: 1.5),
        ),
        hintStyle: const TextStyle(color: textSecondary, fontSize: 13),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: textPrimary, size: 20),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surfaceColor,
        elevation: 0,
        selectedItemColor: accentBlue,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
      ),
      dividerTheme: const DividerThemeData(
        color: dividerColor,
        thickness: 1,
        space: 1,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return accentBlue;
          }
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll(textPrimary),
        side: const BorderSide(color: dividerColor, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      ),
    );
  }
}
