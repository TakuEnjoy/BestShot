import 'dart:io';

void main() {
  final files = [
    'lib/src/screens/groups_screen.dart',
    'lib/src/screens/import_screen.dart',
    'lib/src/screens/loupe_screen.dart',
  ];
  for (final file in files) {
    final f = File(file);
    var content = f.readAsStringSync();
    content = content.replaceAllMapped(
      RegExp(r'\.withOpacity\((.*?)\)'),
      (match) => '.withValues(alpha: ${match.group(1)})',
    );
    f.writeAsStringSync(content);
  }
}
