import 'package:flutter/foundation.dart';
import '../../src/services/analysis/analysis_types.dart';

class ImportViewModel extends ChangeNotifier {
  bool _busy = false;
  bool get busy => _busy;

  String _status = '';
  String get status => _status;

  double? _progress;
  double? get progress => _progress;

  String _stage = '';
  String get stage => _stage;

  DetectionMode _detectionMode = DetectionMode.standard;
  DetectionMode get detectionMode => _detectionMode;

  int _maxCount = 200;
  int get maxCount => _maxCount;

  bool _smartResume = true;
  bool get smartResume => _smartResume;

  int _burstMinutes = 0;
  int get burstMinutes => _burstMinutes;

  int _burstSeconds = 15;
  int get burstSeconds => _burstSeconds;

  static const int burstMinTotal = 1;
  static const int burstMaxTotal = 60 * 60;

  void setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  void updateProgress(String stage, String status, double? progress) {
    _stage = stage;
    _status = status;
    _progress = progress;
    notifyListeners();
  }

  void setError(String error) {
    _busy = false;
    _status = error;
    _stage = '';
    _progress = null;
    notifyListeners();
  }

  void reset() {
    _busy = false;
    _status = '';
    _stage = '';
    _progress = null;
    notifyListeners();
  }

  void setDetectionMode(DetectionMode mode) {
    _detectionMode = mode;
    notifyListeners();
  }

  void setMaxCount(int count) {
    _maxCount = count;
    notifyListeners();
  }

  void setSmartResume(bool value) {
    _smartResume = value;
    notifyListeners();
  }

  void normalizeBurstTotal(int minutes, int seconds) {
    var m = minutes.clamp(0, 60);
    var s = seconds.clamp(0, 59);
    var total = m * 60 + s;
    if (total > burstMaxTotal) {
      total = burstMaxTotal;
      m = total ~/ 60;
      s = total % 60;
    }
    if (total < burstMinTotal) {
      m = 0;
      s = 1;
    }
    _burstMinutes = m;
    _burstSeconds = s;
    notifyListeners();
  }

  int get burstWindowSeconds {
    var total = _burstMinutes * 60 + _burstSeconds;
    if (total < burstMinTotal) total = burstMinTotal;
    if (total > burstMaxTotal) total = burstMaxTotal;
    return total;
  }
}
