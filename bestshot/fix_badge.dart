import 'dart:io';

void main() {
  final mainFile = File('lib/src/screens/groups_screen.dart');
  var mc = mainFile.readAsStringSync();
  mc = mc.replaceAll('SharpnessBadge(', 'Badge(');
  mainFile.writeAsStringSync(mc);
}
