import 'dart:io';

void main() {
  final f = File('lib/src/screens/groups_screen.dart');
  var content = f.readAsStringSync();

  content = content.replaceAll(
    'g.bestKey = _keyboardPhotoKey!;',
    'final idx = widget.groups.indexOf(g);\n            if (idx != -1) widget.groups[idx] = g.copyWith(bestKey: _keyboardPhotoKey!);',
  );

  content = content.replaceAll(
    'g.bestKey = k;',
    'final idx = widget.groups.indexOf(g);\n                        if (idx != -1) widget.groups[idx] = g.copyWith(bestKey: k);',
  );

  content = content.replaceAll(
    'g.bestKey = key;',
    'final idx = widget.groups.indexOf(g);\n                                            if (idx != -1) widget.groups[idx] = g.copyWith(bestKey: key);',
  );

  f.writeAsStringSync(content);
}
