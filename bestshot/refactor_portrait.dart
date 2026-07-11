import 'dart:io';

void main() {
  final file = File('lib/src/models/photo_entry.dart');
  var content = file.readAsStringSync();
  
  content = content.replaceFirst(
    "import 'semantic_object.dart';\nexport 'semantic_object.dart';",
    "import 'semantic_object.dart';\nimport 'portrait_analysis.dart';\nexport 'semantic_object.dart';\nexport 'portrait_analysis.dart';"
  );
  
  content = content.replaceFirst(
    "this.faceQualityScore = 0,\n    this.hasPortraitFace = false,\n    this.portraitEyesClosed = false,\n    this.portraitEyeOpenAvg,\n    this.portraitBothEyesDetected = false,\n    this.portraitFaceX = 0,\n    this.portraitFaceY = 0,\n    this.portraitFaceW = 0,\n    this.portraitFaceH = 0,\n    this.portraitFaceSharpness = 0,\n    this.debugGridSharps,",
    "this.faceQualityScore = 0,\n    this.portrait,\n    this.debugGridSharps,"
  );

  final fieldsToRemove = """  /// Portrait-mode: face detected in ROI analysis.
  final bool hasPortraitFace;

  /// Portrait-mode: true when judged as eyes closed.
  final bool portraitEyesClosed;

  /// Portrait-mode: average eye open probability when available (0..1). -1 if unknown.
  final double? portraitEyeOpenAvg;

  /// Portrait-mode: true when both eyes are confirmed.
  final bool portraitBothEyesDetected;

  /// Portrait-mode: face bounding box in image pixel coordinates.
  final int portraitFaceX;
  final int portraitFaceY;
  final int portraitFaceW;
  final int portraitFaceH;

  /// Portrait-mode: Laplacian variance within face ROI.
  final double portraitFaceSharpness;""";
  
  content = content.replaceFirst(fieldsToRemove, "  /// Portrait-mode analysis results.\n  final PortraitAnalysis? portrait;");

  content = content.replaceFirst(
    "bool? hasPortraitFace,\n    bool? portraitEyesClosed,\n    double? portraitEyeOpenAvg,\n    bool? portraitBothEyesDetected,\n    int? portraitFaceX,\n    int? portraitFaceY,\n    int? portraitFaceW,\n    int? portraitFaceH,\n    double? portraitFaceSharpness,\n    List<double>? debugGridSharps,",
    "PortraitAnalysis? portrait,\n    List<double>? debugGridSharps,"
  );
  
  content = content.replaceFirst(
    "hasPortraitFace: hasPortraitFace ?? this.hasPortraitFace,\n      portraitEyesClosed: portraitEyesClosed ?? this.portraitEyesClosed,\n      portraitEyeOpenAvg: portraitEyeOpenAvg ?? this.portraitEyeOpenAvg,\n      portraitBothEyesDetected:\n          portraitBothEyesDetected ?? this.portraitBothEyesDetected,\n      portraitFaceX: portraitFaceX ?? this.portraitFaceX,\n      portraitFaceY: portraitFaceY ?? this.portraitFaceY,\n      portraitFaceW: portraitFaceW ?? this.portraitFaceW,\n      portraitFaceH: portraitFaceH ?? this.portraitFaceH,\n      portraitFaceSharpness:\n          portraitFaceSharpness ?? this.portraitFaceSharpness,\n      debugGridSharps: debugGridSharps ?? this.debugGridSharps,",
    "portrait: portrait ?? this.portrait,\n      debugGridSharps: debugGridSharps ?? this.debugGridSharps,"
  );
  
  // also fix import_screen.dart
  final isf = File('lib/src/screens/import_screen.dart');
  var isc = isf.readAsStringSync();
  isc = isc.replaceFirst(
    "            hasPortraitFace: a.hasFace,\n            portraitEyesClosed: a.eyesClosed,\n            portraitEyeOpenAvg: a.eyeOpenAvg,\n            portraitBothEyesDetected: a.bothEyesDetected,\n            portraitFaceX: a.faceX,\n            portraitFaceY: a.faceY,\n            portraitFaceW: a.faceW,\n            portraitFaceH: a.faceH,\n            portraitFaceSharpness: a.faceSharpness,\n            debugGridSharps: a.debugGridSharps,",
    "            portrait: PortraitAnalysis(\n              hasFace: a.hasFace,\n              eyesClosed: a.eyesClosed,\n              eyeOpenAvg: a.eyeOpenAvg,\n              bothEyesDetected: a.bothEyesDetected,\n              faceX: a.faceX,\n              faceY: a.faceY,\n              faceW: a.faceW,\n              faceH: a.faceH,\n              faceSharpness: a.faceSharpness,\n            ),\n            debugGridSharps: a.debugGridSharps,"
  );
  isf.writeAsStringSync(isc);
  
  // group screen also accesses portrait fields!
  final gsf = File('lib/src/screens/groups_screen.dart');
  var gsc = gsf.readAsStringSync();
  gsc = gsc.replaceAll('e.hasPortraitFace', '(e.portrait?.hasFace ?? false)');
  gsc = gsc.replaceAll('e.portraitEyesClosed', '(e.portrait?.eyesClosed ?? false)');
  gsc = gsc.replaceAll('e.portraitEyeOpenAvg', 'e.portrait?.eyeOpenAvg');
  gsc = gsc.replaceAll('e.portraitBothEyesDetected', '(e.portrait?.bothEyesDetected ?? false)');
  gsc = gsc.replaceAll('e.portraitFaceSharpness', '(e.portrait?.faceSharpness ?? 0.0)');
  gsf.writeAsStringSync(gsc);
  
  // grouping.dart accesses portrait fields!
  final gf = File('lib/src/services/grouping/grouping.dart');
  var gc = gf.readAsStringSync();
  gc = gc.replaceAll('e.hasPortraitFace', '(e.portrait?.hasFace ?? false)');
  gc = gc.replaceAll('e.portraitEyesClosed', '(e.portrait?.eyesClosed ?? false)');
  gc = gc.replaceAll('e.portraitEyeOpenAvg', 'e.portrait?.eyeOpenAvg');
  gc = gc.replaceAll('e.portraitBothEyesDetected', '(e.portrait?.bothEyesDetected ?? false)');
  gc = gc.replaceAll('e.portraitFaceSharpness', '(e.portrait?.faceSharpness ?? 0.0)');
  gf.writeAsStringSync(gc);

  file.writeAsStringSync(content);
}
