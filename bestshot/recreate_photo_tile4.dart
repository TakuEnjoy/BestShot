import 'dart:io';

void main() {
  final file = File('temp_groups_screen.dart');
  final lines = file.readAsLinesSync();
  
  final mainLines = lines.sublist(0, 1966);
  final bgLines = lines.sublist(1966, 1979);
  final cardLines = lines.sublist(1979, 2149);
  final delLines = lines.sublist(2149, 2377);
  final tileLines = lines.sublist(2377);

  File('lib/src/screens/groups/photo_tile.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'dart:typed_data';\nimport 'dart:ui';\nimport '../../models/photo_entry.dart';\n\n${tileLines.join('\n').replaceAll('_PhotoTile', 'PhotoTile').replaceAll('_Badge', 'SharpnessBadge').replaceAll('Badge(', 'SharpnessBadge(')}\n"
  );
}
