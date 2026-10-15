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
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Use the display size, so iPad split view does not change the cache budget.
    final display = View.of(context).display;
    final isTablet =
        display.size.shortestSide / display.devicePixelRatio >= 600;
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        (isTablet ? 192 : 96) * 1024 * 1024;
    PaintingBinding.instance.imageCache.maximumSize = isTablet ? 600 : 300;
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
