import 'package:flutter/material.dart';

import 'src/app/bestshot_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 * 1024 * 1024; // 256 MB
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  runApp(const BestShotApp());
}
