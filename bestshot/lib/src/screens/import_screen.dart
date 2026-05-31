import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/photo_entry.dart';
import '../services/analysis/analyzer_isolate.dart';
import '../services/analysis/analysis_types.dart';
import '../services/grouping/grouping.dart';
import '../services/importing/import_service.dart';
import '../services/semantic/mlkit_semantic_service.dart';
import 'package:file_picker/file_picker.dart';
import '../platform/folder_picker_windows.dart';
import 'groups_screen.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  String _status = '';
  double? _progress; // null => indeterminate
  String _stage = '';
  DetectionMode _detectionMode = DetectionMode.standard;
  int _maxCount = 200;
  /// 連写ウィンドウ（1秒〜60分）。UIは分・秒で編集、初期 00分15秒。
  int _burstMinutes = 0;
  int _burstSeconds = 15;

  static const int _burstMinTotal = 1;
  static const int _burstMaxTotal = 60 * 60;

  int get _burstWindowSeconds {
    var total = _burstMinutes * 60 + _burstSeconds;
    if (total < _burstMinTotal) total = _burstMinTotal;
    if (total > _burstMaxTotal) total = _burstMaxTotal;
    return total;
  }

  void _normalizeBurstTotal() {
    var m = _burstMinutes.clamp(0, 60);
    var s = _burstSeconds.clamp(0, 59);
    var total = m * 60 + s;
    if (total > _burstMaxTotal) {
      total = _burstMaxTotal;
      m = total ~/ 60;
      s = total % 60;
    }
    if (total < _burstMinTotal) {
      m = 0;
      s = 1;
    }
    setState(() {
      _burstMinutes = m;
      _burstSeconds = s;
    });
  }

  Future<void> _runImportAndAnalyze(
    Future<List<ImportedItem>> Function(void Function(int done, int total) onProgress) importer,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stage = 'インポート';
      _status = '写真を読み込み中...';
      _progress = 0;
    });

    try {
      final imported = await importer((done, total) {
        if (!mounted) return;
        setState(() {
          _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
          _status = '写真を読み込み中... ($done / $total)';
        });
      });
      if (!mounted) return;
      if (imported.isEmpty) {
        setState(() {
          _busy = false;
          _status = '写真が選択されませんでした（権限/対象0件）';
          _stage = '';
          _progress = null;
        });
        return;
      }

      setState(() {
        _stage = '解析';
        _status = 'バックグラウンド解析中（pHash + 鮮鋭度 + 露出）...';
        _progress = 0;
      });
      final analyzed = await AnalyzerIsolate.analyzeAll(
        imported.map((e) => e.toAnalyzeInput()).toList(growable: false),
        mode: _detectionMode,
        rootIsolateToken: RootIsolateToken.instance,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
            _status = 'バックグラウンド解析中... ($done / $total)';
          });
        },
      );

      final byKey = {for (final a in analyzed) a.key: a};

      final entries = <PhotoEntry>[];
      for (final i in imported) {
        final a = byKey[i.key];
        if (a == null) continue;
        entries.add(
          PhotoEntry(
            key: i.key,
            origin: i.origin,
            displayBytes: i.displayBytes,
            assetId: i.assetId,
            filePath: i.filePath,
            pHashHex: a.pHashHex,
            sharpness: a.sharpness,
            exposureScore: a.exposureScore,
            orbRows: a.orbRows,
            orbCols: a.orbCols,
            orbBytes: a.orbBytes,
            histogram: a.histogram,
            exif: i.exifSummary,
            hasPortraitFace: a.hasFace,
            portraitEyesClosed: a.eyesClosed,
            portraitEyeOpenAvg: a.eyeOpenAvg,
            portraitBothEyesDetected: a.bothEyesDetected,
            portraitFaceX: a.faceX,
            portraitFaceY: a.faceY,
            portraitFaceW: a.faceW,
            portraitFaceH: a.faceH,
            portraitFaceSharpness: a.faceSharpness,
            debugGridSharps: a.debugGridSharps,
          ),
        );
      }

      // Semantic analysis (Android/iOS only)
      var enrichedEntries = entries;
      if (Platform.isAndroid || Platform.isIOS) {
        setState(() {
          _stage = '物体/顔検出';
          _status = 'ML Kitで被写体/表情を解析中...';
          _progress = 0;
        });
        final svc = await MlKitSemanticService.create();
        try {
          enrichedEntries = await svc.enrich(
            entries,
            onProgress: (done, total) {
              if (!mounted) return;
              setState(() {
                _progress = total <= 0 ? null : (done / total).clamp(0.0, 1.0);
                _status = 'ML Kit解析中... ($done / $total)';
              });
            },
          );
        } finally {
          await svc.close();
        }
      }

      setState(() {
        _stage = 'グループ化';
        _status = '類似写真をグループ化中...';
        _progress = null;
      });
      final groups = PhotoGrouper.group(
        enrichedEntries,
        GroupingConfig(burstWindowSeconds: _burstWindowSeconds),
      );

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _stage = '';
        _progress = null;
      });

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => GroupsScreen(groups: groups, detectionMode: _detectionMode),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'エラー: $e';
        _stage = '';
        _progress = null;
      });
    }
  }

  Future<void> _runFolderImportAndAnalyze(bool isAndroidSAF) async {
    if (_busy) return;

    // フォルダパスの取得
    String? dir;
    try {
      if (isAndroidSAF) {
        dir = await FilePicker.platform.getDirectoryPath();
      } else {
        dir = FolderPickerWindows.pickFolder();
      }
    } catch (e) {
      setState(() {
        _status = 'フォルダ選択エラー: $e';
      });
      return;
    }

    if (dir == null || dir.isEmpty) return;

    setState(() {
      _busy = true;
      _stage = 'スキャン';
      _status = 'フォルダ内の写真を高速スキャン中...';
      _progress = null;
    });

    try {
      final scanResult = await ImportService.scanFolder(dir);
      if (!mounted) return;

      if (scanResult == null || scanResult.filesByDate.isEmpty) {
        setState(() {
          _busy = false;
          _status = '対象となる画像ファイルが見つかりませんでした';
          _stage = '';
        });
        return;
      }

      // 日付選択ダイアログの表示
      final selectedFiles = await _showDateSelectionDialog(scanResult);
      if (selectedFiles == null || selectedFiles.isEmpty) {
        setState(() {
          _busy = false;
          _status = 'インポートがキャンセルされました';
          _stage = '';
        });
        return;
      }

      // 本解析処理の実行
      await _runImportAndAnalyze(
        (onProgress) => ImportService.importSelectedFiles(
          selectedFiles,
          thumbnailMaxEdge: 512,
          onProgress: onProgress,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'スキャンエラー: $e';
        _stage = '';
      });
    }
  }

  Future<List<File>?> _showDateSelectionDialog(FolderScanResult scanResult) async {
    final filesByDate = scanResult.filesByDate;
    final allDates = filesByDate.keys.toList()..sort((a, b) => b.compareTo(a)); // 初期降順

    final selectedDates = <DateTime>{...allDates}; // デフォルト全選択
    bool descending = true;

    return showDialog<List<File>>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            // 表示用のソート済み日付リスト
            final sortedDates = allDates.toList()
              ..sort((a, b) => descending ? b.compareTo(a) : a.compareTo(b));

            // 現在選択されている写真の合計枚数
            int totalSelected = 0;
            final selectedFilesList = <File>[];
            for (final d in selectedDates) {
              final files = filesByDate[d];
              if (files != null) {
                totalSelected += files.length;
                selectedFilesList.addAll(files);
              }
            }

            final isOverLimit = totalSelected > _maxCount;

            return AlertDialog(
              title: const Text('撮影日（日付）で絞り込み'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'フォルダ: ${scanResult.folderPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    // クイックコントロール行
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  selectedDates.addAll(allDates);
                                });
                              },
                              child: const Text('すべて選択'),
                            ),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  selectedDates.clear();
                                });
                              },
                              child: const Text('クリア'),
                            ),
                          ],
                        ),
                        // 期間で選択
                        TextButton.icon(
                          onPressed: () async {
                            final range = await showDateRangePicker(
                              context: context,
                              firstDate: DateTime(2000),
                              lastDate: DateTime.now().add(const Duration(days: 365)),
                            );
                            if (range != null) {
                              setState(() {
                                selectedDates.clear();
                                for (final d in allDates) {
                                  if (d.isAfter(range.start.subtract(const Duration(seconds: 1))) &&
                                      d.isBefore(range.end.add(const Duration(days: 1)))) {
                                    selectedDates.add(d);
                                  }
                                }
                              });
                            }
                          },
                          icon: const Icon(Icons.date_range, size: 16),
                          label: const Text('期間で選択'),
                        ),
                        // ソートトグル
                        IconButton(
                          tooltip: descending ? '新しい順' : '古い順',
                          icon: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
                          onPressed: () {
                            setState(() {
                              descending = !descending;
                            });
                          },
                        ),
                      ],
                    ),
                    const Divider(),
                    // 日付リスト
                    Flexible(
                      child: Container(
                        height: 240,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: sortedDates.length,
                          itemBuilder: (context, index) {
                            final date = sortedDates[index];
                            final count = filesByDate[date]?.length ?? 0;
                            final dateStr = '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
                            final isChecked = selectedDates.contains(date);

                            return CheckboxListTile(
                              title: Text('$dateStr ($count 枚)'),
                              value: isChecked,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (val) {
                                setState(() {
                                  if (val == true) {
                                    selectedDates.add(date);
                                  } else {
                                    selectedDates.remove(date);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 選択枚数表示と警告
                    Text(
                      '選択中: $totalSelected 枚',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: isOverLimit ? Colors.orange : null,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isOverLimit)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '※ 最大インポート件数（$_maxCount枚）を超えています。上位 $_maxCount枚のみインポートされます。',
                          style: TextStyle(
                            color: Colors.orange.shade800,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('キャンセル'),
                ),
                FilledButton(
                  onPressed: selectedDates.isEmpty
                      ? null
                      : () {
                          final sortedSelectedDates = selectedDates.toList()
                            ..sort((a, b) => b.compareTo(a));

                          final filesToImport = <File>[];
                          for (final d in sortedSelectedDates) {
                            final files = filesByDate[d];
                            if (files != null) {
                              filesToImport.addAll(files);
                            }
                          }

                          final finalFiles = filesToImport.length > _maxCount
                              ? filesToImport.sublist(0, _maxCount)
                              : filesToImport;

                          Navigator.of(context).pop(finalFiles);
                        },
                  child: const Text('選択してインポート'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWindows = Platform.isWindows;
    final isAndroid = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BestShot'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '一眼レフ/ミラーレスの連写・類似写真を、内容ベースでグループ化して「Best」を提案します。',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _InfoCard(),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '検出モード',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<DetectionMode>(
                          initialValue: _detectionMode,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: DetectionMode.standard,
                              child: Text('標準（全体スコア）'),
                            ),
                            DropdownMenuItem(
                              value: DetectionMode.portrait,
                              child: Text('ポートレート（顔優先・目閉じ判定）'),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  // Portrait is supported only on Android/Windows in this build.
                                  if (v == DetectionMode.portrait && !(isWindows || isAndroid)) {
                                    setState(() => _detectionMode = DetectionMode.standard);
                                    return;
                                  }
                                  setState(() => _detectionMode = v);
                                },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '連写としてまとめる時間',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '合計: ${_formatBurstWindow(_burstWindowSeconds)}（1秒〜60分）',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: _burstMinutes.clamp(0, 60),
                                decoration: const InputDecoration(
                                  labelText: '分',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  for (var i = 0; i <= 60; i++)
                                    DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) {
                                        if (v == null) return;
                                        setState(() => _burstMinutes = v);
                                        _normalizeBurstTotal();
                                      },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<int>(
                                initialValue: _burstSeconds.clamp(0, 59),
                                decoration: const InputDecoration(
                                  labelText: '秒',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  for (var i = 0; i < 60; i++)
                                    DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (v) {
                                        if (v == null) return;
                                        setState(() => _burstSeconds = v);
                                        _normalizeBurstTotal();
                                      },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '最大インポート件数',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int>(
                          initialValue: _maxCount,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(value: 50, child: Text('50枚')),
                            DropdownMenuItem(value: 100, child: Text('100枚')),
                            DropdownMenuItem(value: 200, child: Text('200枚')),
                            DropdownMenuItem(value: 500, child: Text('500枚')),
                            DropdownMenuItem(value: 1000, child: Text('1000枚')),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  setState(() => _maxCount = v);
                                },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (isWindows)
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runFolderImportAndAnalyze(false),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダからインポート（Windows）'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _runFolderImportAndAnalyze(true),
                    icon: const Icon(Icons.folder_open),
                    label: const Text('フォルダからインポート（モバイル）'),
                  ),
                const SizedBox(height: 12),
                if (_busy && _stage.isNotEmpty)
                  Text(
                    '処理: $_stage',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                if (_status.isNotEmpty)
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                  ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _progress),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatBurstWindow(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final rem = seconds % 60;
  if (minutes < 60) {
    return rem == 0 ? '$minutes 分' : '$minutes 分 $rem 秒';
  }
  final hours = minutes ~/ 60;
  final minRem = minutes % 60;
  if (minRem == 0 && rem == 0) return '$hours 時間';
  if (rem == 0) return '$hours 時間 $minRem 分';
  return '$hours 時間 $minRem 分 $rem 秒';
}

class _InfoCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DefaultTextStyle(
          style: Theme.of(context).textTheme.bodyMedium!,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('核となるロジック'),
              SizedBox(height: 8),
              Text('- 類似判定: pHash（image_compare / PerceptualHash）'),
              Text('- ピント判定: Laplacian variance（opencv_dart）'),
              Text('- メモリ節約: サムネ優先 + Isolate解析'),
            ],
          ),
        ),
      ),
    );
  }
}

