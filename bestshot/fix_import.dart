import 'dart:io';

void main() {
  final f = File('lib/src/models/photo_entry.dart');
  var c = f.readAsStringSync();
  c = c.replaceFirst(
    "export 'semantic_object.dart';",
    "import 'semantic_object.dart';\nexport 'semantic_object.dart';",
  );
  f.writeAsStringSync(c);
}
