import 'dart:io';

import 'package:flutter/material.dart';

import '../models/photo_entry.dart';
import '../services/analysis/analyzer_isolate.dart';
import '../services/analysis/analysis_types.dart';
import '../services/grouping/grouping.dart';
import '../services/importing/import_service.dart';
import '../services/semantic/mlkit_semantic_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/analysis/embedding_service.dart';
import '../platform/folder_picker_windows.dart';
import 'groups_screen.dart';
import '../core/navigation/fast_route.dart';
import 'package:flutter/services.dart';
import '../theme/bestshot_theme.dart';

class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  bool _busy = false;
  bool _cancelled = false;
  bool _isError = false;
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

  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_busy) return KeyEventResult.ignored;

    final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyO) {
      _runFolderImportAndAnalyze(!Platform.isWindows);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _runFolderImportAndAnalyze(!Platform.isWindows);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showShortcutsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: BestShotTheme.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: BestShotTheme.dividerColor),
        ),
        title: const Row(
          children: [
            Icon(Icons.keyboard_command_key_rounded, size: 20, color: BestShotTheme.accentBlue),
            SizedBox(width: 8),
            Text('キーボードショートカット', style: TextStyle(color: BestShotTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogShortcutRow('Ctrl + O', 'フォルダーを指定してスキャン開始'),
            const SizedBox(height: 8),
            _dialogShortcutRow('Enter', 'インポート開始 / 決定'),
            const SizedBox(height: 8),
            _dialogShortcutRow('Esc', 'ダイアログ / 処理のキャンセル'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる', style: TextStyle(color: BestShotTheme.accentBlue)),
          ),
        ],
      ),
    );
  }

  Widget _dialogShortcutRow(String keyStr, String description) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: BestShotTheme.backgroundPrimary,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: BestShotTheme.dividerColor),
          ),
          child: Text(
            keyStr,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: BestShotTheme.accentGold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            description,
            style: const TextStyle(fontSize: 12, color: BestShotTheme.textPrimary),
          ),
        ),
      ],
    );
  }

  Future<void> _runImportAndAnalyze(
    Future<List<ImportedItem>> Function(
      void Function(int done, int total) onProgress,
    )
    importer, {
    bool skipBusyCheck = false,
  }) async {
    if (!skipBusyCheck && _busy) return;
    setState(() {
      _busy = true;
      _cancelled = false;
      _isError = false;
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

      if (_cancelled) {
        _handleCancelled();
        return;
      }

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
        isCancelled: () => _cancelled,
      );

      if (_cancelled) {
        _handleCancelled();
        return;
      }

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
            orbKeypoints: a.orbKeypoints,
            histogram: a.histogram,
            hueHistogram: a.hueHistogram,
            embeddings: a.embeddings,
            exif: i.exifSummary,
            portrait: PortraitAnalysis(
              hasFace: a.hasFace,
              eyesClosed: a.eyesClosed,
              eyeOpenAvg: a.eyeOpenAvg,
              bothEyesDetected: a.bothEyesDetected,
              faceX: a.faceX,
              faceY: a.faceY,
              faceW: a.faceW,
              faceH: a.faceH,
              faceSharpness: a.faceSharpness,
            ),
            debugGridSharps: a.debugGridSharps,
          ),
        );
      }

      // Embedding feature extraction (ONNX Runtime, Windows / Android)
      final supportDir = await getApplicationSupportDirectory();
      final candidatePaths = [
        p.join(Directory.current.path, 'assets', 'models', 'embedding.onnx'),
        p.join(Directory.current.path, 'models', 'embedding.onnx'),
        p.join(supportDir.path, 'models', 'embedding.onnx'),
      ];
      String? foundModelPath;
      for (final cp in candidatePaths) {
        if (await File(cp).exists()) {
          foundModelPath = cp;
          break;
        }
      }

      if (foundModelPath != null && !_cancelled) {
        final embService = WindowsOnnxEmbeddingService(modelPath: foundModelPath);
        final initialized = await embService.initialize();
        if (initialized) {
          if (mounted) {
            setState(() {
              _stage = '特徴量抽出';
              _status = '画像埋め込み（Embedding）を推論中...';
              _progress = 0;
            });
          }
          try {
            for (var idx = 0; idx < entries.length; idx++) {
              if (_cancelled) break;
              final entry = entries[idx];
              final rawBytes = entry.filePath != null
                  ? await File(entry.filePath!).readAsBytes()
                  : entry.displayBytes;
              final res = await embService.extractEmbeddings(
                rawBytes,
                isLightweight: Platform.isAndroid,
              );
              if (res != null) {
                entries[idx] = entry.copyWith(embeddings: () => res.embeddings);
              }
              if (!mounted) break;
              setState(() {
                _progress = (idx + 1) / entries.length;
                _status = '画像埋め込みを推論中... (${idx + 1} / ${entries.length})';
              });
            }
          } finally {
            embService.dispose();
          }
        }
      }

      if (_cancelled) {
        _handleCancelled();
        return;
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
            isCancelled: () => _cancelled,
          );
        } finally {
          await svc.close();
        }
      }

      if (_cancelled) {
        _handleCancelled();
        return;
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
        FastRoute(
          builder: (context) =>
              GroupsScreen(groups: groups, detectionMode: _detectionMode),
        ),
      );
    } catch (e, stack) {
      if (!mounted) return;
      if (_cancelled) {
        _handleCancelled();
      } else {
        setState(() {
          _busy = false;
          _isError = true;
          _status = 'エラーが発生しました';
          _stage = '';
          _progress = null;
        });
        _showErrorDialog(e, stack);
      }
    }
  }

  void _handleCancelled() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '処理がキャンセルされました';
      _stage = '';
      _progress = null;
    });
  }

  void _showErrorDialog(Object error, StackTrace stackTrace) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red),
              SizedBox(width: 8),
              Text('エラー詳細'),
            ],
          ),
          content: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            width: MediaQuery.of(context).size.width * 0.9,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '処理中に以下のエラーが発生しました：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      error.toString(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'スタックトレース：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 200),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        stackTrace.toString(),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
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
        skipBusyCheck: true,
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

  Future<List<File>?> _showDateSelectionDialog(
    FolderScanResult scanResult,
  ) async {
    final filesByDate = scanResult.filesByDate;
    final allDates = filesByDate.keys.toList()
      ..sort((a, b) => b.compareTo(a)); // 初期降順

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
              backgroundColor: BestShotTheme.surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: const BorderSide(color: BestShotTheme.dividerColor),
              ),
              title: const Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 18, color: BestShotTheme.accentBlue),
                  SizedBox(width: 8),
                  Text('撮影日（日付）で絞り込み', style: TextStyle(color: BestShotTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Container(
                constraints: const BoxConstraints(maxWidth: 480),
                width: MediaQuery.of(context).size.width * 0.9,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'フォルダー: ${scanResult.folderPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: BestShotTheme.textSecondary, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    // クイックコントロール行
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Wrap(
                          spacing: 6,
                          children: [
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: BestShotTheme.dividerColor),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                setState(() {
                                  selectedDates.addAll(allDates);
                                });
                              },
                              child: const Text('すべて選択', style: TextStyle(color: BestShotTheme.textPrimary, fontSize: 12)),
                            ),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: BestShotTheme.dividerColor),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                setState(() {
                                  selectedDates.clear();
                                });
                              },
                              child: const Text('クリア', style: TextStyle(color: BestShotTheme.textSecondary, fontSize: 12)),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 期間で選択
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: BestShotTheme.dividerColor),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () async {
                                final range = await showDateRangePicker(
                                  context: context,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime.now().add(const Duration(days: 365)),
                                  builder: (context, child) => Theme(
                                    data: ThemeData.dark().copyWith(
                                      colorScheme: const ColorScheme.dark(
                                        primary: BestShotTheme.accentBlue,
                                        surface: BestShotTheme.surfaceColor,
                                      ),
                                    ),
                                    child: child!,
                                  ),
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
                              icon: const Icon(Icons.date_range, size: 14, color: BestShotTheme.accentBlue),
                              label: const Text('期間で選択', style: TextStyle(color: BestShotTheme.textPrimary, fontSize: 12)),
                            ),
                            const SizedBox(width: 4),
                            // ソートトグル
                            IconButton(
                              tooltip: descending ? '新しい順' : '古い順',
                              icon: Icon(
                                descending ? Icons.arrow_downward : Icons.arrow_upward,
                                size: 16,
                                color: BestShotTheme.textSecondary,
                              ),
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
                    const Divider(color: BestShotTheme.dividerColor, height: 16),
                    // 日付リスト
                    Flexible(
                      child: Container(
                        height: 240,
                        decoration: BoxDecoration(
                          color: BestShotTheme.backgroundPrimary,
                          border: Border.all(color: BestShotTheme.dividerColor),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: sortedDates.length,
                          itemBuilder: (context, index) {
                            final date = sortedDates[index];
                            final count = filesByDate[date]?.length ?? 0;
                            final dateStr =
                                '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
                            final isChecked = selectedDates.contains(date);

                            return CheckboxListTile(
                              title: Text(
                                '$dateStr ($count 枚)',
                                style: const TextStyle(fontSize: 13, color: BestShotTheme.textPrimary),
                              ),
                              value: isChecked,
                              activeColor: BestShotTheme.accentBlue,
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
                    Row(
                      children: [
                        Text(
                          '選択中: $totalSelected 枚',
                          style: TextStyle(
                            color: isOverLimit ? BestShotTheme.accentGold : BestShotTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        if (isOverLimit) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '※ 上限 ($_maxCount枚) を超えた分は自動除外されます',
                              style: const TextStyle(color: BestShotTheme.accentGold, fontSize: 11),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: BestShotTheme.dividerColor),
                    foregroundColor: BestShotTheme.textSecondary,
                  ),
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('キャンセル'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BestShotTheme.accentBlue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
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
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 850;
    final isSmallMobile = size.width < 600;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        backgroundColor: BestShotTheme.backgroundPrimary,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _buildTopBar(context, isSmallMobile, isWindows),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isWide ? 1200 : 640),
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: isSmallMobile ? 14 : 24,
                  vertical: isSmallMobile ? 12 : 20,
                ),
                child: isWide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // メインステージ (ドロップゾーン、進捗、ステータス)
                          Expanded(
                            flex: 6,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildDropzone(context, isWindows, isSmallMobile),
                                _buildProgressDisplay(),
                                _buildStatusDisplay(),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          // 右側インスペクター (パイプライン設定、エンジン仕様、システム診断)
                          Expanded(
                            flex: 4,
                            child: _buildParametersSidebar(context, isSmallMobile, isAndroid),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildDropzone(context, isWindows, isSmallMobile),
                          _buildProgressDisplay(),
                          _buildStatusDisplay(),
                          const SizedBox(height: 16),
                          _buildParametersSidebar(context, isSmallMobile, isAndroid),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, bool isSmallMobile, bool isWindows) {
    return Container(
      height: 56,
      padding: EdgeInsets.symmetric(horizontal: isSmallMobile ? 14 : 24),
      decoration: const BoxDecoration(
        color: BestShotTheme.backgroundPrimary,
        border: Border(bottom: BorderSide(color: BestShotTheme.dividerColor, width: 1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: BestShotTheme.accentBlue.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: BestShotTheme.accentBlue.withValues(alpha: 0.3)),
            ),
            child: const Icon(
              Icons.camera,
              size: 18,
              color: BestShotTheme.accentBlue,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'BestShot',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        letterSpacing: 0.5,
                        color: BestShotTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: BestShotTheme.surfaceColor,
                        borderRadius: BorderRadius.circular(2),
                        border: Border.all(color: BestShotTheme.dividerColor),
                      ),
                      child: const Text(
                        'PRO',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: BestShotTheme.accentGold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!isSmallMobile)
                  Text(
                    'CULLING & BEST SHOT WORKSTATION',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w500,
                      color: BestShotTheme.textSecondary.withValues(alpha: 0.8),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Engine status indicator
          Container(
            padding: EdgeInsets.symmetric(horizontal: isSmallMobile ? 6 : 10, vertical: 4),
            decoration: BoxDecoration(
              color: BestShotTheme.surfaceColor,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: BestShotTheme.dividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _busy ? BestShotTheme.accentGold : BestShotTheme.accentGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                if (!isSmallMobile) ...[
                  const SizedBox(width: 6),
                  Text(
                    _busy ? 'PROCESSING' : 'ENGINE READY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: _busy ? BestShotTheme.accentGold : BestShotTheme.accentGreen,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!isSmallMobile && isWindows) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'キーボードショートカット [Ctrl+O]',
              icon: const Icon(Icons.keyboard_command_key_rounded, size: 18, color: BestShotTheme.textSecondary),
              onPressed: () => _showShortcutsDialog(context),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPipelineMiniSteps(bool isSmallMobile) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: BestShotTheme.backgroundPrimary,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: BestShotTheme.dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _miniStep('01', 'フォルダー選択', active: true),
          _miniArrow(),
          _miniStep('02', '鮮鋭度・特徴量解析'),
          if (!isSmallMobile) ...[
            _miniArrow(),
            _miniStep('03', 'Best自動抽出'),
            _miniArrow(),
            _miniStep('04', '仕分け'),
          ],
        ],
      ),
    );
  }

  Widget _miniStep(String num, String label, {bool active = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          num,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
            color: active ? BestShotTheme.accentBlue : BestShotTheme.textSecondary,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            color: active ? BestShotTheme.textPrimary : BestShotTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _miniArrow() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Icon(Icons.chevron_right, size: 12, color: BestShotTheme.textSecondary),
    );
  }

  Widget _buildDropzone(BuildContext context, bool isWindows, bool isSmallMobile) {
    if (_busy) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isSmallMobile ? 20 : 36,
        vertical: isSmallMobile ? 28 : 44,
      ),
      decoration: BoxDecoration(
        color: BestShotTheme.surfaceColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: BestShotTheme.dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPipelineMiniSteps(isSmallMobile),
          SizedBox(height: isSmallMobile ? 28 : 36),
          Icon(
            Icons.folder_open_rounded,
            size: isSmallMobile ? 48 : 56,
            color: BestShotTheme.accentBlue,
          ),
          const SizedBox(height: 16),
          Text(
            isWindows ? 'フォルダーを指定してスキャン開始' : 'スキャンするフォルダーを選択',
            style: TextStyle(
              fontSize: isSmallMobile ? 16 : 19,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.3,
              color: BestShotTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '一眼レフ・ミラーレスのRAW/JPEG連写を高精度解析し、ベストショットを自動抽出',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: BestShotTheme.textSecondary.withValues(alpha: 0.9),
              height: 1.4,
            ),
          ),
          SizedBox(height: isSmallMobile ? 24 : 32),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: BestShotTheme.accentBlue,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(
                horizontal: isSmallMobile ? 28 : 36,
                vertical: isSmallMobile ? 14 : 16,
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              elevation: 0,
            ),
            onPressed: () => _runFolderImportAndAnalyze(!isWindows),
            icon: const Icon(Icons.folder_open, size: 20),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isWindows ? 'フォルダーを開く' : 'フォルダーを選択',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 0.3),
                ),
                if (isWindows) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Text('Ctrl+O', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white70)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_outline, size: 12, color: BestShotTheme.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '対応: RAW (DNG/CR2/NEF/ARW)  •  JPEG / HEIF  •  PNG',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.3,
                    color: BestShotTheme.textSecondary.withValues(alpha: 0.8),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressDisplay() {
    if (!_busy) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: BestShotTheme.surfaceColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: BestShotTheme.dividerColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: BestShotTheme.accentBlue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  _stage.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: BestShotTheme.accentBlue,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _status,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: BestShotTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_progress != null)
                Text(
                  '${(_progress! * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    color: BestShotTheme.accentBlue,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              backgroundColor: BestShotTheme.backgroundPrimary,
              valueColor: const AlwaysStoppedAnimation<Color>(BestShotTheme.accentBlue),
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: BestShotTheme.accentRed),
              foregroundColor: BestShotTheme.accentRed,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            onPressed: () {
              setState(() {
                _status = 'キャンセル中...';
                _cancelled = true;
              });
            },
            icon: const Icon(Icons.cancel_outlined, size: 16),
            label: const Text('処理を中断', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDisplay() {
    if (_busy || _status.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: _isError
              ? BestShotTheme.accentRed.withValues(alpha: 0.1)
              : BestShotTheme.surfaceColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: _isError
                ? BestShotTheme.accentRed.withValues(alpha: 0.5)
                : BestShotTheme.dividerColor,
          ),
        ),
        child: Row(
          children: [
            Icon(
              _isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              color: _isError ? BestShotTheme.accentRed : BestShotTheme.accentBlue,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _status,
                style: TextStyle(
                  color: _isError ? BestShotTheme.accentRed : BestShotTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParametersSidebar(BuildContext context, bool isSmallMobile, bool isAndroid) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: BestShotTheme.surfaceColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: BestShotTheme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune_rounded, size: 15, color: BestShotTheme.accentBlue),
              SizedBox(width: 8),
              Text(
                'PIPELINE CONFIGURATION',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: BestShotTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // 1. 検出モード
          const Text(
            '検出・評価モード (Detection Mode)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: BestShotTheme.textPrimary),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _modeSegmentItem(
                  title: '標準モード',
                  icon: Icons.auto_awesome_mosaic_outlined,
                  selected: _detectionMode == DetectionMode.standard,
                  onTap: _busy ? null : () => setState(() => _detectionMode = DetectionMode.standard),
                ),
              ),
              if (isAndroid) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _modeSegmentItem(
                    title: 'ポートレート',
                    icon: Icons.face_rounded,
                    selected: _detectionMode == DetectionMode.portrait,
                    onTap: _busy ? null : () => setState(() => _detectionMode = DetectionMode.portrait),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // 2. 連写判定インターバル
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  '連写・同一シーン判定時間窓',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: BestShotTheme.textPrimary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatBurstWindow(_burstWindowSeconds),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: BestShotTheme.accentGold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _presetBurstChip(5, '5秒 (連写)'),
              _presetBurstChip(15, '15秒 (標準)'),
              _presetBurstChip(30, '30秒 (長連写)'),
              _presetBurstChip(60, '60秒 (1分)'),
              _customBurstChip(),
            ],
          ),
          // カスタム入力行
          if (_isCustomBurstSelected()) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: BestShotTheme.backgroundPrimary,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: BestShotTheme.dividerColor),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _burstMinutes.clamp(0, 60),
                      dropdownColor: BestShotTheme.surfaceColor,
                      decoration: const InputDecoration(
                        labelText: '分 (Min)',
                        labelStyle: TextStyle(fontSize: 10, color: BestShotTheme.textSecondary),
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      items: [
                        for (var i = 0; i <= 60; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(i.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 11)),
                          ),
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
                  const SizedBox(width: 6),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _burstSeconds.clamp(0, 59),
                      dropdownColor: BestShotTheme.surfaceColor,
                      decoration: const InputDecoration(
                        labelText: '秒 (Sec)',
                        labelStyle: TextStyle(fontSize: 10, color: BestShotTheme.textSecondary),
                        border: OutlineInputBorder(),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                      items: [
                        for (var i = 0; i < 60; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(i.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 11)),
                          ),
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
            ),
          ],
          const SizedBox(height: 16),

          // 3. 最大インポート件数
          const Text(
            '最大インポート件数 (Batch Limit)',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: BestShotTheme.textPrimary),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: [
              _presetMaxCountChip(50, '50枚'),
              _presetMaxCountChip(100, '100枚'),
              _presetMaxCountChip(200, '200枚 (標準)'),
              _presetMaxCountChip(500, '500枚'),
              _presetMaxCountChip(1000, '1000枚'),
            ],
          ),
          const SizedBox(height: 18),
          const Divider(color: BestShotTheme.dividerColor, height: 1),
          const SizedBox(height: 12),

          // 5. システム診断
          const Text(
            'SYSTEM DIAGNOSTICS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: BestShotTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          _diagnosticRow('Isolate Pool', '${Platform.numberOfProcessors} Threads Active'),
          _diagnosticRow('Memory Cache', '256MB LRU Image Cache'),
          _diagnosticRow('Engines', 'Laplacian + ORB + pHash 64bit'),
        ],
      ),
    );
  }

  bool _isCustomBurstSelected() {
    return !([5, 15, 30, 60].contains(_burstWindowSeconds));
  }

  Widget _presetBurstChip(int seconds, String label) {
    final selected = _burstWindowSeconds == seconds;
    return InkWell(
      onTap: _busy
          ? null
          : () {
              setState(() {
                _burstMinutes = seconds ~/ 60;
                _burstSeconds = seconds % 60;
              });
            },
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? BestShotTheme.accentBlue.withValues(alpha: 0.2) : BestShotTheme.backgroundPrimary,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.dividerColor,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _customBurstChip() {
    final selected = _isCustomBurstSelected();
    return InkWell(
      onTap: _busy
          ? null
          : () {
              if (!selected) {
                setState(() {
                  _burstMinutes = 0;
                  _burstSeconds = 45; // Default custom value
                });
              }
            },
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? BestShotTheme.accentBlue.withValues(alpha: 0.2) : BestShotTheme.backgroundPrimary,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.dividerColor,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          'カスタム',
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _presetMaxCountChip(int count, String label) {
    final selected = _maxCount == count;
    return InkWell(
      onTap: _busy ? null : () => setState(() => _maxCount = count),
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? BestShotTheme.accentBlue.withValues(alpha: 0.2) : BestShotTheme.backgroundPrimary,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.dividerColor,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.textSecondary,
          ),
        ),
      ),
    );
  }


  Widget _modeSegmentItem({
    required String title,
    required IconData icon,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? BestShotTheme.accentBlue.withValues(alpha: 0.15) : BestShotTheme.backgroundPrimary,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: selected ? BestShotTheme.accentBlue : BestShotTheme.dividerColor,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: selected ? BestShotTheme.accentBlue : BestShotTheme.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? BestShotTheme.textPrimary : BestShotTheme.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _diagnosticRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: BestShotTheme.textSecondary)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: BestShotTheme.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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


