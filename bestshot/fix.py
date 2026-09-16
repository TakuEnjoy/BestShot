import re

with open('lib/src/services/analysis/analyzer_isolate.dart', 'r') as f:
    content = f.read()

# Replace _portraitAnalyzeAndroid function completely
start_marker = "  static Future<_PortraitResult> _portraitAnalyzeAndroid("
end_marker = "    }\n  }\n\n  static Future<String> _ensureAssetFile"

# Find the start and end positions
start_idx = content.find(start_marker)
end_idx = content.find(end_marker)

if start_idx != -1 and end_idx != -1:
    replacement = """  static Future<_PortraitResult> _portraitAnalyzeAndroid(
    Uint8List bytes, {
    required NativeFaceDetector faceDetector,
    required Directory tmpDir,
  }) async {
    cv.Mat? mat;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return const _PortraitResult.none();
      }

      final fp = p.join(
        tmpDir.path,
        'bestshot_portrait_${bytes.length}_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      final file = File(fp);
      await file.writeAsBytes(bytes, flush: true);

      final faces = await faceDetector.processImage(fp);

      if (await file.exists()) {
        await file.delete();
      }

      if (faces.isEmpty) {
        return const _PortraitResult.none();
      }

      final imageWidth = mat.cols;
      final imageHeight = mat.rows;

      // Find largest area
      double maxArea = 0;
      for (final f in faces) {
        final area = f.width * imageWidth * f.height * imageHeight;
        if (area > maxArea) {
          maxArea = area;
        }
      }

      // Keep faces >= 25% of largest area
      final mainFaces = faces.where((f) {
        final area = f.width * imageWidth * f.height * imageHeight;
        return area >= (maxArea * 0.25);
      }).toList();

      if (mainFaces.isEmpty) return const _PortraitResult.none();

      var primaryFace = mainFaces.first;
      var primaryArea = primaryFace.width * imageWidth * primaryFace.height * imageHeight;
      for (final f in mainFaces.skip(1)) {
        final area = f.width * imageWidth * f.height * imageHeight;
        if (area > primaryArea) {
          primaryFace = f;
          primaryArea = area;
        }
      }

      double totalFaceSharpness = 0.0;
      double minEyeOpen = 1.0;
      bool anyEyesClosed = false;
      bool allBothEyesDetected = true;
      bool anyBothEyesDetected = false;

      for (final face in mainFaces) {
        final rx = (face.x * imageWidth).round().clamp(0, imageWidth - 1);
        final ry = (face.y * imageHeight).round().clamp(0, imageHeight - 1);
        final rw = (face.width * imageWidth).round().clamp(1, imageWidth - rx);
        final rh = (face.height * imageHeight).round().clamp(1, imageHeight - ry);

        final roi = cv.Rect(rx, ry, rw, rh);
        var fSharp = _calcLaplacianVarianceInRoi(mat, roi);
        if (fSharp <= 0) {
          fSharp = _fallbackLaplacianVariance(bytes, x: rx, y: ry, w: rw, h: rh);
        }
        totalFaceSharpness += fSharp;

        final le = face.leftEyeOpenProbability;
        final re = face.rightEyeOpenProbability;
        double? faceEyeAvg;
        var faceEyesClosed = false;

        if (le != null && re != null) {
          faceEyeAvg = (le + re) / 2.0;
          anyBothEyesDetected = true;
          faceEyesClosed = (faceEyeAvg < 0.4) || (le < 0.2) || (re < 0.2);
        } else if (le != null) {
          faceEyeAvg = le;
          faceEyesClosed = le < 0.4;
          allBothEyesDetected = false;
        } else if (re != null) {
          faceEyeAvg = re;
          faceEyesClosed = re < 0.4;
          allBothEyesDetected = false;
        } else {
          allBothEyesDetected = false;
        }

        if (faceEyeAvg != null) {
          if (faceEyeAvg < minEyeOpen) {
            minEyeOpen = faceEyeAvg;
          }
          if (faceEyesClosed) {
            anyEyesClosed = true;
          }
        }
      }

      final avgFaceSharpness = totalFaceSharpness / mainFaces.length;
      final finalEyeOpenAvg = (minEyeOpen == 1.0 && !anyBothEyesDetected) ? null : minEyeOpen;

      final prx = (primaryFace.x * imageWidth).round();
      final pry = (primaryFace.y * imageHeight).round();
      final prw = (primaryFace.width * imageWidth).round();
      final prh = (primaryFace.height * imageHeight).round();

      return _PortraitResult(
        hasFace: true,
        faceX: prx,
        faceY: pry,
        faceW: prw,
        faceH: prh,
        faceSharpness: avgFaceSharpness,
        eyeOpenAvg: finalEyeOpenAvg,
        eyesClosed: anyEyesClosed,
        bothEyesDetected: allBothEyesDetected,
        eyeSharpness: -1.0, // Eye landmarks not supported natively yet
      );
    } catch (e) {
      return const _PortraitResult.none();
    } finally {
      mat?.dispose();
"""
    new_content = content[:start_idx] + replacement + content[end_idx:]
    with open('lib/src/services/analysis/analyzer_isolate.dart', 'w') as f:
        f.write(new_content)
    print("Replaced successfully!")
else:
    print(f"Could not find markers: {start_idx}, {end_idx}")

