import 'package:flutter/material.dart';

import '../screens/import_screen.dart';

class BestShotApp extends StatelessWidget {
  const BestShotApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1), // Neon Indigo
      brightness: Brightness.dark,
    ).copyWith(
      background: const Color(0xFF090D16), // Ultra Deep Slate Blue/Black
      surface: const Color(0xFF111827), // Deep Card Charcoal
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFF10B981), // Emerald Accent
      error: const Color(0xFFEF4444),
    );

    return MaterialApp(
      title: 'BestShot 正式版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF090D16),
        cardTheme: CardThemeData(
          color: const Color(0xFF111827),
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF1F2937), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF090D16),
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const ImportScreen(),
    );
  }
}

