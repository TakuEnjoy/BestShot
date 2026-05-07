import 'package:flutter/material.dart';

import '../screens/import_screen.dart';

class BestShotApp extends StatelessWidget {
  const BestShotApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F46E5),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'BestShot 正式版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
      ),
      home: const ImportScreen(),
    );
  }
}

