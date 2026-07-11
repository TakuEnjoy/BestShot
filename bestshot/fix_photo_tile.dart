import 'dart:io';

void main() {
  final file = File('lib/src/screens/groups/photo_tile.dart');
  var lines = file.readAsLinesSync();
  
  // 1. Add import 'dart:ui';
  if (!lines.any((l) => l.contains("import 'dart:ui';"))) {
    lines.insert(0, "import 'dart:ui';");
  }

  // 2. Fix the missing bracket for Semantics(child: InkWell(... Stack(...)))
  // The first InkWell ends at line 372:
  //                 ],
  //               ),
  //             ),
  //           ),
  //         ),
  //       ),
  //     ),
  //   );
  
  // Let's find "                ]," which is line 371
  int stackEnd = lines.indexWhere((l) => l.trim() == "],");
  if (stackEnd != -1) {
    // The InkWell ends at lines[stackEnd + 2] which is "            ),"
    lines[stackEnd + 2] = "            ),";
    lines.insert(stackEnd + 3, "            ),"); // close Semantics
  }

  // 3. Fix the missing bracket for Semantics(child: InkWell( Container(...) ))
  // Around line 335
  int loupeEnd = lines.indexWhere((l) => l.contains("widget.loupeSelected"));
  int loupeIconEnd = lines.indexWhere((l) => l.contains("Icons.zoom_in,"), loupeEnd);
  // Actually, we can search for the end of the second InkWell.
  // It's after `size: 18, color: Colors.white),`
  int iconEnd = lines.indexWhere((l) => l.contains("size: 18, color: Colors.white),"));
  if (iconEnd != -1) {
    // lines[iconEnd] is "                          size: 18, color: Colors.white),"
    // lines[iconEnd + 1] is "                        )," // Container
    // lines[iconEnd + 2] is "                      )," // InkWell
    // We need to add "                      )," // Semantics
    lines.insert(iconEnd + 3, "                      ),");
  }

  file.writeAsStringSync(lines.join('\n'));
}
