import 'dart:io';

void main() {
  final file = File('lib/src/screens/groups/photo_tile.dart');
  var ptc = file.readAsStringSync();
  ptc = ptc.replaceAll('SharpnessSharpnessBadge', 'SharpnessBadge');
  
  // Wrap InkWells in photo_tile
  ptc = ptc.replaceAll(
    '            child: InkWell(\n              onTap: () => widget.onChanged(!widget.selectedForDelete),',
    "            child: Semantics(\n              label: widget.selectedForDelete ? '削除候補から外す' : '削除候補にする',\n              button: true,\n              child: InkWell(\n                onTap: () => widget.onChanged(!widget.selectedForDelete),"
  );
  ptc = ptc.replaceAll(
    '                ],\n              ),\n            ),\n          ),\n        ),\n      ),\n    );\n  }\n}',
    '                ],\n              ),\n            ),\n            ),\n          ),\n        ),\n      ),\n    );\n  }\n}'
  );
  
  ptc = ptc.replaceAll(
    '                      child: InkWell(\n                        onTap: widget.onToggleLoupe,',
    "                      child: Semantics(\n                        label: widget.loupeSelected ? 'ルーペを閉じる' : 'ルーペで拡大する',\n                        button: true,\n                        child: InkWell(\n                          onTap: widget.onToggleLoupe,"
  );
  ptc = ptc.replaceAll(
    '                          size: 18, color: Colors.white),\n                        ),\n                      ),\n                    ),\n                  ),',
    '                          size: 18, color: Colors.white),\n                        ),\n                      ),\n                      ),\n                    ),\n                  ),'
  );

  file.writeAsStringSync(ptc);
}
