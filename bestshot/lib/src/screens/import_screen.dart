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
      setState(() {
        _busy = false;
      });
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
              content: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                width: MediaQuery.of(context).size.width * 0.9,
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
                    // クイックコントロール行（折り返し対応のWrap）
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Wrap(
                          spacing: 4,
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
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 800;
    final isSmallMobile = size.width < 600;

    // 1. Premium Hero Header
    final heroHeader = Container(
      padding: EdgeInsets.all(isSmallMobile ? 12 : 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colorScheme.primary.withOpacity(0.08),
            colorScheme.secondary.withOpacity(0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colorScheme.primary.withOpacity(0.15),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.auto_awesome_motion_rounded,
            size: isSmallMobile ? 28 : 40,
            color: colorScheme.primary,
          ),
          SizedBox(height: isSmallMobile ? 8 : 12),
          Text(
            '最高の瞬間を、AIが提案します。',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              fontSize: isSmallMobile ? 14 : null,
              color: Colors.white.withOpacity(0.95),
            ),
          ),
          SizedBox(height: isSmallMobile ? 4 : 6),
          Text(
            '一眼レフやミラーレス of 連写・類似写真を、内容ベースで高速グループ化して「Best」を見つけ出します。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: Colors.white.withOpacity(0.65),
              fontSize: isSmallMobile ? 10 : null,
              height: 1.4,
            ),
          ),
        ],
      ),
    );

    // 2. Info Card (Tech specs)
    final infoCard = _InfoCard();

    // 3. Parameters Card
    final parametersCard = Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(isSmallMobile ? 12 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune_rounded, size: isSmallMobile ? 16 : 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '解析・グループ化設定',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: isSmallMobile ? 14 : null,
                  ),
                ),
              ],
            ),
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '検出モード',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withOpacity(0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<DetectionMode>(
              isExpanded: true,
              initialValue: _detectionMode,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: isSmallMobile ? 8 : 12),
              ),
              items: [
                const DropdownMenuItem(
                  value: DetectionMode.standard,
                  child: Text('標準（全体ピント・構図スコア）'),
                ),
                if (isAndroid)
                  const DropdownMenuItem(
                    value: DetectionMode.portrait,
                    child: Text('ポートレート（顔優先・目閉じ判定）'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      if (v == null) return;
                      if (v == DetectionMode.portrait && !isAndroid) {
                        setState(() => _detectionMode = DetectionMode.standard);
                        return;
                      }
                      setState(() => _detectionMode = v);
                    },
            ),
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '連写としてまとめる時間窓',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withOpacity(0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '合計: ${_formatBurstWindow(_burstWindowSeconds)}（1秒〜60分以内を1グループ化）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withOpacity(0.5),
                fontSize: isSmallMobile ? 10 : null,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _burstMinutes.clamp(0, 60),
                    decoration: InputDecoration(
                      labelText: '分',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                      contentPadding: isSmallMobile ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8) : null,
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
                SizedBox(width: isSmallMobile ? 8 : 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _burstSeconds.clamp(0, 59),
                    decoration: InputDecoration(
                      labelText: '秒',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      isDense: true,
                      contentPadding: isSmallMobile ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8) : null,
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
            SizedBox(height: isSmallMobile ? 10 : 16),
            Text(
              '最大インポート件数',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white.withOpacity(0.8),
                fontSize: isSmallMobile ? 11 : null,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _maxCount,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
                contentPadding: isSmallMobile ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8) : null,
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
    );

    // 4. Hero Import Button (Beautiful Gradient Action Box)
    Widget? importButton;
    if (!_busy) {
      importButton = Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF4F46E5)], // Indigo gradients
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withOpacity(0.3),
              blurRadius: 16,
              spreadRadius: 2,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _runFolderImportAndAnalyze(!isWindows),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: isSmallMobile ? 16 : 24, horizontal: 12),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(isSmallMobile ? 8 : 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.folder_open_rounded,
                      size: isSmallMobile ? 24 : 32,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: isSmallMobile ? 8 : 12),
                  Text(
                    isWindows ? 'フォルダを指定してインポート' : 'スキャンするフォルダを選択',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 14 : 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'サブフォルダ内の画像も自動的に再帰スキャンされます',
                    style: TextStyle(
                      fontSize: isSmallMobile ? 10 : 11,
                      color: Colors.white.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // 5. Status and Progress Display
    Widget? progressDisplay;
    if (_busy) {
      progressDisplay = Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: colorScheme.primary.withOpacity(0.2),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3.5,
              ),
            ),
            const SizedBox(height: 16),
            if (_stage.isNotEmpty)
              Text(
                _stage,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
            const SizedBox(height: 6),
            Text(
              _status,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withOpacity(0.85),
              ),
            ),
            if (_progress != null) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 8,
                  backgroundColor: colorScheme.primary.withOpacity(0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(_progress! * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // 6. Non-busy error/info status
    Widget? errorDisplay;
    if (!_busy && _status.isNotEmpty) {
      errorDisplay = Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _status.contains('エラー')
                ? colorScheme.error.withOpacity(0.12)
                : colorScheme.secondary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _status.contains('エラー')
                  ? colorScheme.error.withOpacity(0.3)
                  : colorScheme.secondary.withOpacity(0.2),
            ),
          ),
          child: Row(
            children: [
              Icon(
                _status.contains('エラー')
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                color: _status.contains('エラー')
                    ? colorScheme.error
                    : colorScheme.secondary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _status,
                  style: TextStyle(
                    color: _status.contains('エラー')
                        ? colorScheme.error
                        : Colors.white.withOpacity(0.9),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF818CF8), Color(0xFF34D399)], // Indigo to Emerald
          ).createShader(bounds),
          child: const Text(
            'BestShot',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 24,
              letterSpacing: 1.5,
              color: Colors.white,
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isWide ? 1150 : 580),
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: isSmallMobile ? 16 : 24,
              vertical: isSmallMobile ? 12 : 20,
            ),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 左カラム (説明、インポートボタン、進捗、InfoCard)
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            heroHeader,
                            const SizedBox(height: 24),
                            if (importButton != null) importButton,
                            if (progressDisplay != null) progressDisplay,
                            if (errorDisplay != null) errorDisplay,
                            const SizedBox(height: 24),
                            infoCard,
                          ],
                        ),
                      ),
                      const SizedBox(width: 24),
                      // 右カラム (設定パネル)
                      Expanded(
                        flex: 4,
                        child: parametersCard,
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      heroHeader,
                      SizedBox(height: isSmallMobile ? 12 : 20),
                      infoCard,
                      SizedBox(height: isSmallMobile ? 12 : 20),
                      parametersCard,
                      SizedBox(height: isSmallMobile ? 16 : 24),
                      if (importButton != null) importButton,
                      if (progressDisplay != null) progressDisplay,
                      if (errorDisplay != null) errorDisplay,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.analytics_rounded,
              color: colorScheme.secondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI判定ロジックについて',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  DefaultTextStyle(
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: Colors.white.withOpacity(0.65),
                      height: 1.4,
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('• 類似グルーピング: 高精度PerceptualHash (pHash) 解析'),
                        Text('• ピント解像評価: OpenCV Laplacian分散 による輪郭抽出'),
                        Text('• メモリ保護: 画像の軽量サムネイル化 ＆ 別Isolateでの並列解析'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

