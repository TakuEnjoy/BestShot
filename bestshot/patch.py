import re
import sys

file_path = "lib/src/services/analysis/analyzer_isolate.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Replace import
content = content.replace(
    "import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';",
    "import '../semantic/native_face_detector.dart';"
)

# 2. Remove Windows Haar cascade init logic in analyzeAll
content = re.sub(
    r"    if \(mode == DetectionMode\.portrait && Platform\.isWindows\) \{.*?    \}\n\n    final isMobile = Platform\.isAndroid \|\| Platform\.isIOS;",
    "    final isMobile = true;",
    content,
    flags=re.DOTALL
)

# 3. Replace inside _entryAsync
old_init = """    final isAndroid = Platform.isAndroid;
    final isWindows = Platform.isWindows;

    FaceDetector? faceDetector;
    Directory? tmpDir;
    cv.CascadeClassifier? faceCascade;
    cv.CascadeClassifier? eyeCascade;

    if (message.mode == DetectionMode.portrait && isAndroid) {
      faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableClassification: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
      tmpDir = await getTemporaryDirectory();
    } else if (message.mode == DetectionMode.portrait && isWindows) {
      final support = await getApplicationSupportDirectory();
      final cascadeDir = Directory(p.join(support.path, 'cascades'));
      faceCascade = cv.CascadeClassifier.empty();
      faceCascade.load(p.join(cascadeDir.path, 'haarcascade_frontalface_default.xml'));
      eyeCascade = cv.CascadeClassifier.empty();
      eyeCascade.load(p.join(cascadeDir.path, 'haarcascade_eye.xml'));
    }"""
new_init = """    NativeFaceDetector? faceDetector;
    Directory? tmpDir;
    cv.CascadeClassifier? faceCascade;
    cv.CascadeClassifier? eyeCascade;

    if (message.mode == DetectionMode.portrait) {
      faceDetector = NativeFaceDetector();
      tmpDir = await getTemporaryDirectory();
    }"""
content = content.replace(old_init, new_init)

# 4. Signature of _analyzeOne
content = content.replace(
    "FaceDetector? faceDetector,",
    "NativeFaceDetector? faceDetector,"
)

# 5. Usage in _analyzeOne
old_usage = """      if (mode == DetectionMode.portrait) {
        if (Platform.isAndroid && faceDetector != null && tmpDir != null) {
          final r = await _portraitAnalyzeAndroid(
            rawBytes, // Use extracted JPEG for RAW files
            faceDetector: faceDetector,
            tmpDir: tmpDir,
          );
          hasFace = r.hasFace;
          faceX = r.faceX;
          faceY = r.faceY;
          faceW = r.faceW;
          faceH = r.faceH;
          faceSharpness = r.faceSharpness;
          eyeSharpness = r.eyeSharpness;
          faceQualityScore = r.faceQualityScore;

          if (r.hasFace && r.faceSharpness > 0) {
            sharpnessForScore = r.faceSharpness;
          }
        } else if (Platform.isWindows &&
            faceCascade != null &&
            eyeCascade != null) {
          final r = _portraitAnalyzeWindows(
            rawBytes,
            faceCascade: faceCascade,
            eyeCascade: eyeCascade,
          );
          hasFace = r.hasFace;
          faceX = r.faceX;
          faceY = r.faceY;
          faceW = r.faceW;
          faceH = r.faceH;
          faceSharpness = r.faceSharpness;
          eyeSharpness = r.eyeSharpness;

          if (r.hasFace && r.faceSharpness > 0) {
            sharpnessForScore = r.faceSharpness;
          }
        }
      }"""
new_usage = """      if (mode == DetectionMode.portrait) {
        if (faceDetector != null && tmpDir != null) {
          final r = await _portraitAnalyzeNative(
            rawBytes,
            faceDetector: faceDetector,
            tmpDir: tmpDir,
          );
          hasFace = r.hasFace;
          faceX = r.faceX;
          faceY = r.faceY;
          faceW = r.faceW;
          faceH = r.faceH;
          faceSharpness = r.faceSharpness;
          eyeSharpness = r.eyeSharpness;
          faceQualityScore = r.faceQualityScore;

          if (r.hasFace && r.faceSharpness > 0) {
            sharpnessForScore = r.faceSharpness;
          }
        }
      }"""
content = content.replace(old_usage, new_usage)

# 6. Replace _portraitAnalyzeAndroid and _portraitAnalyzeWindows with _portraitAnalyzeNative
# We will use regex to remove the old methods and insert the new one.
content = re.sub(
    r"  static Future<_PortraitResult> _portraitAnalyzeAndroid\(.*?  \}\n\n  static _PortraitResult _portraitAnalyzeWindows\(.*?  \}",
    """  static Future<_PortraitResult> _portraitAnalyzeNative(
    Uint8List bytes, {
    required NativeFaceDetector faceDetector,
    required Directory tmpDir,
  }) async {
    cv.Mat? mat;
    try {
      mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      if (mat.isEmpty) {
        return _PortraitResult();
      }

      final uniqueId = DateTime.now().microsecondsSinceEpoch.toString();
      final fp = p.join(tmpDir.path, 'analyzer_face_$uniqueId.jpg');
      final file = File(fp);
      await file.writeAsBytes(bytes, flush: true);

      final faces = await faceDetector.processImage(fp);

      if (await file.exists()) {
        await file.delete();
      }

      if (faces.isEmpty) {
        return _PortraitResult();
      }

      NativeFace? largestFace;
      double maxArea = 0;
      for (final f in faces) {
        final area = f.width * f.height;
        if (area > maxArea) {
          maxArea = area;
          largestFace = f;
        }
      }
      final f = largestFace!;

      final w = mat.cols.toDouble();
      final h = mat.rows.toDouble();
      
      final nx = f.x;
      final ny = f.y;
      final nw = f.width;
      final nh = f.height;

      final rx = (nx * w).toInt().clamp(0, mat.cols - 1);
      final ry = (ny * h).toInt().clamp(0, mat.rows - 1);
      final rw = (nw * w).toInt().clamp(1, mat.cols - rx);
      final rh = (nh * h).toInt().clamp(1, mat.rows - ry);

      final faceRect = cv.Rect(rx, ry, rw, rh);
      final faceCrop = mat.region(faceRect);
      
      cv.Mat? grayFace;
      cv.Mat? laplacian;
      double faceSharpness = -1.0;
      try {
        grayFace = cv.cvtColor(faceCrop, cv.COLOR_BGR2GRAY);
        laplacian = cv.laplacian(grayFace, cv.CV_64F, ksize: 3);
        final meanStdDev = cv.meanStdDev(laplacian);
        final stdDev = meanStdDev.stddev.val[0];
        faceSharpness = stdDev * stdDev;
      } finally {
        grayFace?.dispose();
        laplacian?.dispose();
        faceCrop.dispose();
      }

      double qualityScore = 0.0;
      final s = f.smilingProbability;
      final le = f.leftEyeOpenProbability;
      final re = f.rightEyeOpenProbability;
      final parts = <double>[];
      if (s != null) parts.add(s);
      if (le != null) parts.add(le);
      if (re != null) parts.add(re);
      if (parts.isNotEmpty) {
        qualityScore = parts.reduce((a, b) => a + b) / parts.length;
      }

      return _PortraitResult(
        hasFace: true,
        faceX: nx,
        faceY: ny,
        faceW: nw,
        faceH: nh,
        faceSharpness: faceSharpness,
        eyeSharpness: faceSharpness,
        faceQualityScore: qualityScore,
      );
    } catch (e, stack) {
      developer.log('Error in _portraitAnalyzeNative: $e\\n$stack');
      return _PortraitResult();
    } finally {
      mat?.dispose();
    }
  }""",
    content,
    flags=re.DOTALL
)

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Patched analyzer_isolate.dart")
