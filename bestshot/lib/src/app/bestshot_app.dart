import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../screens/import_screen.dart';

class BestShotApp extends StatefulWidget {
  const BestShotApp({super.key});

  @override
  State<BestShotApp> createState() => _BestShotAppState();
}

final _colorScheme =
    ColorScheme.fromSeed(
      seedColor: const Color(0xFF6366F1), // Neon Indigo
      brightness: Brightness.dark,
    ).copyWith(
      surface: const Color(0xFF111827), // Deep Card Charcoal
      primary: const Color(0xFF6366F1),
      secondary: const Color(0xFF10B981), // Emerald Accent
      error: const Color(0xFFEF4444),
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
      SystemNavigator.pop();
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
