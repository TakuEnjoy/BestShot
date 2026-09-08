import 'dart:io';
import 'package:flutter/material.dart';

import '../screens/import_screen.dart';

class BestShotApp extends StatefulWidget {
  const BestShotApp({super.key});

  @override
  State<BestShotApp> createState() => _BestShotAppState();
}

final _colorScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF4F6BFF), // Expressive Electric Indigo
  brightness: Brightness.dark,
).copyWith(
  surface: const Color(0xFF131316),
  surfaceDim: const Color(0xFF0F0F12),
  surfaceBright: const Color(0xFF383842),
  surfaceContainerLowest: const Color(0xFF0C0C0F),
  surfaceContainerLow: const Color(0xFF1B1B21),
  surfaceContainer: const Color(0xFF212128),
  surfaceContainerHigh: const Color(0xFF2B2B33),
  surfaceContainerHighest: const Color(0xFF363640),
  primary: const Color(0xFF8298FF),
  onPrimary: const Color(0xFF001E6A),
  primaryContainer: const Color(0xFF253B98),
  onPrimaryContainer: const Color(0xFFDFE2FF),
  secondary: const Color(0xFF67E2D9),
  onSecondary: const Color(0xFF003734),
  secondaryContainer: const Color(0xFF1B4E4C),
  onSecondaryContainer: const Color(0xFFBCEEE9),
  tertiary: const Color(0xFFFFB1C8),
  onTertiary: const Color(0xFF5E1133),
  tertiaryContainer: const Color(0xFF7E2A49),
  onTertiaryContainer: const Color(0xFFFFD9E2),
  error: const Color(0xFFFFB4AB),
  onError: const Color(0xFF690005),
  errorContainer: const Color(0xFF93000A),
  onErrorContainer: const Color(0xFFFFDAD6),
  outline: const Color(0xFF8E9099),
  outlineVariant: const Color(0xFF44474F),
);

class _BestShotAppState extends State<BestShotApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // ウィンドウが閉じられアプリが破棄される際、
      // バックグラウンドのIsolateがReceivePortで待機したままプロセスがゾンビ化するのを防ぐため強制終了する
      // SystemNavigator.pop() ではなく exit(0) を使ってOSレベルでプロセスを終了させる
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BestShot 正式版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: _colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamilyFallback: const ['Segoe UI', 'Roboto', 'Noto Sans JP', 'sans-serif'],
        cardTheme: CardThemeData(
          color: const Color(0xFF1E1E26).withValues(alpha: 0.5),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
          clipBehavior: Clip.antiAlias,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.3),
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: const StadiumBorder(),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.2), width: 1.2),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF1E1E26).withValues(alpha: 0.8),
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
          titleTextStyle: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        chipTheme: ChipThemeData(
          shape: const StadiumBorder(),
          side: const BorderSide(color: Colors.transparent),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: const Color(0xFF2B2B36).withValues(alpha: 0.9),
          contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.2),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFF8298FF), width: 2),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const ImportScreen(),
    );
  }
}
