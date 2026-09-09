import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';

import '../screens/import_screen.dart';
import '../theme/bestshot_theme.dart';

class BestShotApp extends StatefulWidget {
  const BestShotApp({super.key});

  @override
  State<BestShotApp> createState() => _BestShotAppState();
}

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
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BestShot Professional',
      debugShowCheckedModeBanner: false,
      theme: BestShotTheme.darkTheme,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          PointerDeviceKind.mouse,
          PointerDeviceKind.touch,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      home: const ImportScreen(),
    );
  }
}
