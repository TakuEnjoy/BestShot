import 'dart:io';

void main() {
  final file = File('lib/src/screens/groups_screen.dart');
  final lines = file.readAsLinesSync();

  final mainLines = lines.sublist(0, 1966);
  final bgLines = lines.sublist(1966, 1979);
  final cardLines = lines.sublist(1979, 2149);
  final delLines = lines.sublist(2149, 2377);
  final tileLines = lines.sublist(2377);

  File('lib/src/screens/groups/background_task.dart').writeAsStringSync(
    "${bgLines.join('\n').replaceAll('_BackgroundTask', 'BackgroundTask')}\n",
  );

  File('lib/src/screens/groups/expandable_group_card.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport '../../models/photo_group.dart';\nimport 'photo_tile.dart';\n\n${cardLines.join('\n').replaceAll('_ExpandableGroupCard', 'ExpandableGroupCard').replaceAll('_PhotoTile', 'PhotoTile')}\n",
  );

  File('lib/src/screens/groups/delete_review_screen.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport 'dart:typed_data';\nimport 'package:photo_manager/photo_manager.dart';\nimport '../../models/photo_entry.dart';\nimport 'photo_tile.dart';\nimport '../../services/deleting/delete_service.dart';\n\n${delLines.join('\n').replaceAll('_PhotoTile', 'PhotoTile')}\n",
  );

  File('lib/src/screens/groups/photo_tile.dart').writeAsStringSync(
    "import 'package:flutter/material.dart';\nimport 'package:flutter/services.dart';\nimport 'dart:typed_data';\nimport '../../models/photo_entry.dart';\n\n${tileLines.join('\n').replaceAll('_PhotoTile', 'PhotoTile').replaceAll('_Badge', 'Badge')}\n",
  );

  var newMain = mainLines.join('\n');
  newMain =
      "import 'groups/background_task.dart';\nimport 'groups/expandable_group_card.dart';\nimport 'groups/delete_review_screen.dart';\nimport 'groups/photo_tile.dart';\n$newMain";
  newMain = newMain.replaceAll('_BackgroundTask', 'BackgroundTask');
  newMain = newMain.replaceAll('_ExpandableGroupCard', 'ExpandableGroupCard');
  newMain = newMain.replaceAll('_PhotoTile', 'PhotoTile');

  file.writeAsStringSync(newMain);
}
