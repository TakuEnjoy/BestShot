import 'dart:io';

void main() {
  // Fix groups_screen.dart
  final gsFile = File('lib/src/screens/groups_screen.dart');
  var gsc = gsFile.readAsStringSync();
  gsc = gsc.replaceAll('e.portrait?.hasFace', 'e.portrait.hasFace');
  gsc = gsc.replaceAll('e.portrait?.eyesClosed', 'e.portrait.eyesClosed');
  gsc = gsc.replaceAll('e.portrait?.eyeOpenAvg', 'e.portrait.eyeOpenAvg');
  gsc = gsc.replaceAll('e.portrait?.bothEyesDetected', 'e.portrait.bothEyesDetected');
  gsc = gsc.replaceAll('e.portrait?.faceSharpness', 'e.portrait.faceSharpness');
  gsc = gsc.replaceAll('(e.portrait.hasFace ?? false)', 'e.portrait.hasFace');
  gsc = gsc.replaceAll('(e.portrait.eyesClosed ?? false)', 'e.portrait.eyesClosed');
  gsc = gsc.replaceAll('(e.portrait.bothEyesDetected ?? false)', 'e.portrait.bothEyesDetected');
  gsc = gsc.replaceAll('(e.portrait.faceSharpness ?? 0.0)', 'e.portrait.faceSharpness');
  gsFile.writeAsStringSync(gsc);

  // Fix grouping.dart
  final gpFile = File('lib/src/services/grouping/grouping.dart');
  var gpc = gpFile.readAsStringSync();
  gpc = gpc.replaceAll('e.portrait?.hasFace', 'e.portrait.hasFace');
  gpc = gpc.replaceAll('e.portrait?.eyesClosed', 'e.portrait.eyesClosed');
  gpc = gpc.replaceAll('e.portrait?.eyeOpenAvg', 'e.portrait.eyeOpenAvg');
  gpc = gpc.replaceAll('e.portrait?.bothEyesDetected', 'e.portrait.bothEyesDetected');
  gpc = gpc.replaceAll('e.portrait?.faceSharpness', 'e.portrait.faceSharpness');
  gpc = gpc.replaceAll('(e.portrait.hasFace ?? false)', 'e.portrait.hasFace');
  gpc = gpc.replaceAll('(e.portrait.eyesClosed ?? false)', 'e.portrait.eyesClosed');
  gpc = gpc.replaceAll('(e.portrait.bothEyesDetected ?? false)', 'e.portrait.bothEyesDetected');
  gpc = gpc.replaceAll('(e.portrait.faceSharpness ?? 0.0)', 'e.portrait.faceSharpness');
  gpFile.writeAsStringSync(gpc);

  // Fix loupe_screen.dart
  final lsFile = File('lib/src/screens/loupe_screen.dart');
  var lsc = lsFile.readAsStringSync();
  lsc = lsc.replaceAll('e.hasPortraitFace', 'e.portrait.hasFace');
  lsc = lsc.replaceAll('e.portraitFaceX', 'e.portrait.faceX');
  lsc = lsc.replaceAll('e.portraitFaceY', 'e.portrait.faceY');
  lsc = lsc.replaceAll('e.portraitFaceW', 'e.portrait.faceW');
  lsc = lsc.replaceAll('e.portraitFaceH', 'e.portrait.faceH');
  lsc = lsc.replaceAll('item.hasPortraitFace', 'item.portrait.hasFace');
  lsc = lsc.replaceAll('item.portraitFaceX', 'item.portrait.faceX');
  lsc = lsc.replaceAll('item.portraitFaceY', 'item.portrait.faceY');
  lsc = lsc.replaceAll('item.portraitFaceW', 'item.portrait.faceW');
  lsc = lsc.replaceAll('item.portraitFaceH', 'item.portrait.faceH');
  lsFile.writeAsStringSync(lsc);
}
