import 'dart:io';

void main() {
  final file = File('lib/src/screens/groups/photo_tile.dart');
  var content = file.readAsStringSync();
  content = content.replaceAllMapped(RegExp(r'\.withValues\(alpha: \$1\)'), (m) => '.withValues(alpha: 0.5)'); // Actually, wait, let me just replace what I did
  file.writeAsStringSync(content);
}
