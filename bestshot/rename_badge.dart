import 'dart:io';

void main() {
  final photoTileFile = File('lib/src/screens/groups/photo_tile.dart');
  var ptc = photoTileFile.readAsStringSync();
  ptc = ptc.replaceAll('class Badge ', 'class SharpnessBadge ');
  ptc = ptc.replaceAll('Badge(', 'SharpnessBadge(');
  photoTileFile.writeAsStringSync(ptc);

  final mainFile = File('lib/src/screens/groups_screen.dart');
  var mc = mainFile.readAsStringSync();
  mc = mc.replaceAll('Badge(', 'SharpnessBadge(');
  mainFile.writeAsStringSync(mc);
}
