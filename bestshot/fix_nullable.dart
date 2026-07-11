import 'dart:io';

void main() {
  final f = File('lib/src/screens/groups_screen.dart');
  var c = f.readAsStringSync();
  c = c.replaceFirst(
    'if (e.portraitEyeOpenAvg >= 0)',
    'if (e.portraitEyeOpenAvg != null && e.portraitEyeOpenAvg! >= 0)',
  );
  c = c.replaceFirst(
    '\${e.portraitEyeOpenAvg.toStringAsFixed(2)}',
    '\${e.portraitEyeOpenAvg!.toStringAsFixed(2)}',
  );
  f.writeAsStringSync(c);
}
