import 'dart:io';
import 'package:flutter/material.dart';

import '../screens/import_screen.dart';

class BestShotApp extends StatefulWidget {
  const BestShotApp({super.key});

  @override
  State<BestShotApp> createState() => _BestShotAppState();
}

final _colorScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF3B82F6), // Calm Blue
  brightness: Brightness.dark,
).copyWith(
  surface: const Color(0xFF252526), // Panel Charcoal (VSCode-like)
  primary: const Color(0xFF3B82F6),
  secondary: const Color(0xFF3B82F6), // Use single accent color
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
        scaffoldBackgroundColor: const Color(0xFF1E1E1E), // App Base Dark Grey
        cardTheme: CardThemeData(
          color: const Color(0xFF252526),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFF333333), width: 1),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
        ),
      ),
      home: const ImportScreen(),
    );
  }
}
