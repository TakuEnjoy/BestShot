import 'dart:io';

void main() {
  final file = File('lib/src/screens/groups/photo_tile.dart');
  var content = file.readAsStringSync();
  content = content.replaceAll(RegExp(r'\.withOpacity\(([^)]+)\)'), '.withValues(alpha: \$1)');
  file.writeAsStringSync(content);
}
