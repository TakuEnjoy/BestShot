import 'dart:io';

void main() {
  final file = File('temp_groups_screen.dart');
  final lines = file.readAsLinesSync();
  
  final startIndex = lines.indexWhere((l) => l.startsWith('class _PhotoTile'));
  if (startIndex == -1) {
    print('Not found');
    return;
  }
  final tileLines = lines.sublist(startIndex);

  File('lib/src/screens/groups/photo_tile.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'dart:typed_data';\nimport '../../models/photo_entry.dart';\n\n${tileLines.join('\n').replaceAll('_PhotoTile', 'PhotoTile').replaceAll('_Badge', 'SharpnessBadge').replaceAll('Badge(', 'SharpnessBadge(')}\n"
  );
}
