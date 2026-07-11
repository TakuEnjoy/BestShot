import 'dart:io';

void main() async {
  final result = await Process.run('git', ['show', 'HEAD:lib/src/screens/groups_screen.dart']);
  final text = result.stdout as String;
  final lines = text.split('\n');
  final tileLines = lines.sublist(2377);

  File('lib/src/screens/groups/photo_tile.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'dart:typed_data';\nimport '../../models/photo_entry.dart';\n\n${tileLines.join('\n').replaceAll('_PhotoTile', 'PhotoTile').replaceAll('_Badge', 'SharpnessBadge').replaceAll('Badge(', 'SharpnessBadge(')}\n"
  );
}
