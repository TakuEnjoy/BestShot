import 'dart:io';

void main() {
  final f = File('lib/src/services/analysis/analyzer_isolate.dart');
  var c = f.readAsStringSync();
  c = c.replaceFirst('cv.Mat? work;', 'late cv.Mat work;');
  f.writeAsStringSync(c);
}
