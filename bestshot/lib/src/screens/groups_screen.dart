import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/photo_entry.dart';
import '../models/photo_group.dart';
import '../services/analysis/analysis_types.dart';
import '../services/deleting/delete_service.dart';
import '../services/sorting/sort_service.dart';
import 'loupe_screen.dart';

part 'groups/background_task.dart';
part 'groups/expandable_group_card.dart';
part 'groups/delete_review_screen.dart';
part 'groups/photo_tile.dart';
part 'groups/badge.dart';

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({
    super.key,
    required this.groups,
    required this.detectionMode,
  });

  final List<PhotoGroup> groups;
  final DetectionMode detectionMode;

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  late final Map<String, PhotoEntry> _entryByKey;
  List<PhotoEntry>? _sortedPortraitItems;
  late final Set<String> _selectedForDelete;
  final List<String> _loupeSelection = [];
  late List<PhotoGroup> _groups;

  // 仕分け用の状態変数
  final Map<String, String> _selectedSortFolders = {};
  final List<String> _customFolders = [];

  // バックグラウンド処理用の状態
  final Set<String> _processingKeys = {};
  final List<_BackgroundTask> _backgroundTasks = [];

  // Keyboard focus management
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  int _keyboardGroupIndex = 0;
  String? _keyboardPhotoKey;
  int _keyboardPortraitIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _scrollController = ScrollController();

    // Request focus after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });

    _groups = List.of(widget.groups);

    _entryByKey = {
      for (final g in _groups)
        for (final e in g.items) e.key: e,
    };
    _selectedForDelete = {
      for (final g in _groups) ...g.deleteCandidateKeys,
    };

    // Initialize keyboard photo focus to the first bestKey
    if (_groups.isNotEmpty) {
      _keyboardPhotoKey = _groups.first.bestKey;
    }
  }

  @override
  void didUpdateWidget(GroupsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groups != widget.groups) {
      _groups = List.of(widget.groups);
      _entryByKey.clear();
      for (final g in _groups) {
        for (final e in g.items) {
          _entryByKey[e.key] = e;
        }
      }
      _sortedPortraitItems = null;
    }
  }

  void _syncEntryByKey() {
    _entryByKey.clear();
    for (final g in _groups) {
      for (final e in g.items) {
        _entryByKey[e.key] = e;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _clampKeyboardIndices() {
    if (_groups.isEmpty) {
      _keyboardGroupIndex = 0;
      _keyboardPortraitIndex = 0;
      _keyboardPhotoKey = null;
      return;
    }
    if (_keyboardGroupIndex >= _groups.length) {
      _keyboardGroupIndex = _groups.length - 1;
    }
    // Note: _sortedPortraitItems is not available here easily without state,
    // so _keyboardPortraitIndex clamp might need to happen elsewhere if needed.
  }

  List<PhotoEntry> _getPortraitItems() {
    if (widget.detectionMode != DetectionMode.portrait) return const <PhotoEntry>[];
    if (_sortedPortraitItems != null) return _sortedPortraitItems!;
    
    final items = _entryByKey.values.toList();
    items.sort((a, b) {
      final fa = a.portrait.hasFace ? 0 : 1;
      final fb = b.portrait.hasFace ? 0 : 1;
      final faceCmp = fa.compareTo(fb);
      if (faceCmp != 0) return faceCmp;
      final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return ta.compareTo(tb);
    });
    _sortedPortraitItems = items;
    return items;
  }

  int get _selectedCount => _selectedForDelete.length;

  Future<void> _exportBestShots() async {
    final selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return; // Cancelled

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("ベストショットをエクスポート中..."),
              ],
            ),
          ),
        );
      },
    );

    try {
      int count = 0;
      for (final group in _groups) {
        if (group.items.isEmpty) continue;
        final bestItem = group.items.firstWhere(
          (item) => item.key == group.bestKey,
          orElse: () => group.items.first,
        );

        final sourcePath = bestItem.filePath;
        if (sourcePath == null) continue;
        final file = File(sourcePath);
        if (await file.exists()) {
          final filename = p.basename(sourcePath);
          final destPath = p.join(selectedDirectory, filename);

          var finalDestPath = destPath;
          var suffix = 1;
          final nameWithoutExt = p.basenameWithoutExtension(sourcePath);
          final ext = p.extension(sourcePath);
          while (await File(finalDestPath).exists()) {
            finalDestPath = p.join(selectedDirectory, '${nameWithoutExt}_$suffix$ext');
            suffix++;
          }

          await file.copy(finalDestPath);
          count++;
        }
      }

      if (mounted) {
        Navigator.of(context).pop(); // Close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count 枚のベストショットをエクスポートしました。'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エクスポート中にエラーが発生しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      // Nothing
    }
  }

  Future<void> _reviewAndDelete() async {
    // 処理中のファイルを除外した削除候補を抽出
    final targets = _selectedForDelete
        .where((k) => !_processingKeys.contains(k))
        .toList();

    if (targets.isEmpty) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DeleteReviewScreen(
          items: targets.map((k) => _entryByKey[k]).whereType<PhotoEntry>().toList(),
          onRemoveFromDelete: (key) {
            setState(() => _selectedForDelete.remove(key));
          },
        ),
      ),
    );

    if (result == true) {
      // 念のため、実行直前に再度処理中のキーが混入していないかダブルチェック
      final finalTargets = targets
          .where((k) => !_processingKeys.contains(k))
          .toList();

      if (finalTargets.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('選択された写真はすでに処理中です。')),
          );
        }
        return;
      }

      setState(() {
        _processingKeys.addAll(finalTargets);
        _selectedForDelete.removeAll(finalTargets);
      });

      final taskId = 'delete_${DateTime.now().millisecondsSinceEpoch}';
      final task = _BackgroundTask(
        id: taskId,
        title: 'ゴミ箱へ移動中',
        total: finalTargets.length,
      );

      setState(() {
        _backgroundTasks.add(task);
      });

      // バックグラウンドで実行（awaitせず進む）
      _executeDeleteInBackground(task, finalTargets);
    }
  }

  Future<void> _executeDeleteInBackground(
    _BackgroundTask task,
    List<String> targets,
  ) async {
    final entries = targets
        .map((k) => _entryByKey[k])
        .whereType<PhotoEntry>()
        .toList();

    try {
      setState(() {
        task.progress = 0.5;
        task.statusText = 'ゴミ箱へ移動中...';
      });

      await DeleteService.moveToTrash(entries);

      if (mounted) {
        setState(() {
          _processingKeys.removeAll(targets);

          for (final entry in entries) {
            for (var i = 0; i < _groups.length; i++) {
              final g = _groups[i];
              if (g.items.any((item) => item.key == entry.key)) {
                final newItems = g.items.where((item) => item.key != entry.key).toList();
                _groups[i] = g.copyWith(items: newItems);
              }
            }
          }
          _groups.removeWhere((g) => g.items.isEmpty);
          _syncEntryByKey();
          _sortedPortraitItems = null;
          _clampKeyboardIndices();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ゴミ箱へ移動しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processingKeys.removeAll(targets);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('削除失敗: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _backgroundTasks.removeWhere((t) => t.id == task.id);
        });
      }
    }
  }

  void _scrollToActiveGroup(bool isPortrait) {
    if (!_scrollController.hasClients) return;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 800;
    final isMobile = size.width < 600;
    final crossAxisCount = size.width >= 800 ? 2 : 1;

    if (isPortrait) {
      double targetOffset;
      if (isWide) {
        final itemWidth = (size.width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
        final itemHeight = itemWidth / 0.82 + 16;
        final rowIndex = _keyboardPortraitIndex ~/ crossAxisCount;
        targetOffset = rowIndex * itemHeight;
      } else if (isMobile) {
        final itemWidth = (size.width - 24 - 12) / 2;
        final itemHeight = itemWidth / 0.82 + 12;
        final rowIndex = _keyboardPortraitIndex ~/ 2;
        targetOffset = rowIndex * itemHeight;
      } else {
        targetOffset = _keyboardPortraitIndex * 130.0;
      }
      final currentOffset = _scrollController.offset;
      final viewHeight = size.height;
      if (targetOffset < currentOffset || targetOffset > currentOffset + viewHeight - 250) {
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    } else {
      final targetOffset = _keyboardGroupIndex * 220.0;
      final currentOffset = _scrollController.offset;
      final viewHeight = size.height;
      if (targetOffset < currentOffset || targetOffset > currentOffset + viewHeight - 300) {
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isPortrait = widget.detectionMode == DetectionMode.portrait;
    final portraitItems = _getPortraitItems();

    // 編集用キーボードショートカットの場合は処理中のファイルを保護
    final bool isEditKey = key == LogicalKeyboardKey.keyB ||
        key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1 ||
        key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2 ||
        key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3 ||
        key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4 ||
        key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5 ||
        key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6 ||
        key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7 ||
        key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8 ||
        key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9 ||
        key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0;

    if (isEditKey) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty ? portraitItems[_keyboardPortraitIndex].key : null)
          : _keyboardPhotoKey;
      if (targetKey != null && _processingKeys.contains(targetKey)) {
        return KeyEventResult.handled; // 現在処理中の写真なので操作を無効化
      }
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        if (isPortrait) {
          if (portraitItems.isNotEmpty && _keyboardPortraitIndex < portraitItems.length - 1) {
            _keyboardPortraitIndex++;
            _scrollToActiveGroup(true);
          }
        } else {
          if (_groups.isNotEmpty && _keyboardGroupIndex < _groups.length - 1) {
            _keyboardGroupIndex++;
            final g = _groups[_keyboardGroupIndex];
            if (g.items.isNotEmpty) {
              _keyboardPhotoKey = g.bestKey;
            }
            _scrollToActiveGroup(false);
          }
        }
      });
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        if (isPortrait) {
          if (_keyboardPortraitIndex > 0) {
            _keyboardPortraitIndex--;
            _scrollToActiveGroup(true);
          }
        } else {
          if (_keyboardGroupIndex > 0) {
            _keyboardGroupIndex--;
            final g = _groups[_keyboardGroupIndex];
            if (g.items.isNotEmpty) {
              _keyboardPhotoKey = g.bestKey;
            }
            _scrollToActiveGroup(false);
          }
        }
      });
      return KeyEventResult.handled;
    }

    if (!isPortrait && _groups.isNotEmpty) {
      final g = _groups[_keyboardGroupIndex];
      final items = g.items;
      final currentIndex = items.indexWhere((e) => e.key == _keyboardPhotoKey);

      if (key == LogicalKeyboardKey.arrowRight) {
        if (currentIndex != -1 && currentIndex < items.length - 1) {
          setState(() {
            _keyboardPhotoKey = items[currentIndex + 1].key;
          });
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.arrowLeft) {
        if (currentIndex > 0) {
          setState(() {
            _keyboardPhotoKey = items[currentIndex - 1].key;
          });
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.keyB) {
        if (_keyboardPhotoKey != null) {
          setState(() {
            final idx = _groups.indexOf(g);
            if (idx != -1) {
              _groups[idx] = g.copyWith(bestKey: _keyboardPhotoKey!);
            }
          });
        }
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final activeKey = isPortrait
          ? (portraitItems.isNotEmpty ? portraitItems[_keyboardPortraitIndex].key : null)
          : _keyboardPhotoKey;
      if (activeKey != null) {
        final targetKeys = _loupeSelection.isNotEmpty
            ? _loupeSelection.toList()
            : [activeKey];

        final items = targetKeys
            .map((k) => _entryByKey[k])
            .whereType<PhotoEntry>()
            .toList();
        if (items.isNotEmpty) {
          _openLoupe(items);
        }
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyL) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty ? portraitItems[_keyboardPortraitIndex].key : null)
          : _keyboardPhotoKey;
      if (targetKey != null) {
        setState(() {
          if (_loupeSelection.contains(targetKey)) {
            _loupeSelection.remove(targetKey);
          } else {
            if (_loupeSelection.length < 4) {
              _loupeSelection.add(targetKey);
            }
          }
        });
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty ? portraitItems[_keyboardPortraitIndex].key : null)
          : _keyboardPhotoKey;
      if (targetKey != null) {
        setState(() {
          if (_selectedForDelete.contains(targetKey)) {
            _selectedForDelete.remove(targetKey);
          } else {
            _selectedForDelete.add(targetKey);
          }
        });
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.delete) {
      _reviewAndDelete();
      return KeyEventResult.handled;
    }

    int? getFolderIndex(LogicalKeyboardKey key) {
      if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) return 0;
      if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) return 1;
      if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) return 2;
      if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) return 3;
      if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) return 4;
      if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) return 5;
      if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) return 6;
      if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) return 7;
      if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) return 8;
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) return 9;
      return null;
    }

    final folderIndex = getFolderIndex(key);
    if (folderIndex != null && folderIndex < _customFolders.length) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty ? portraitItems[_keyboardPortraitIndex].key : null)
          : _keyboardPhotoKey;
      if (targetKey != null) {
        setState(() {
          final targetFolder = _customFolders[folderIndex];
          if (_selectedSortFolders[targetKey] == targetFolder) {
            _selectedSortFolders.remove(targetKey);
          } else {
            _selectedSortFolders[targetKey] = targetFolder;
          }
        });

        // 爆速仕分けのために、割り当て完了後に自動で次の写真にフォーカスを移動する
        if (isPortrait) {
          if (_keyboardPortraitIndex < portraitItems.length - 1) {
            setState(() {
              _keyboardPortraitIndex++;
              _scrollToActiveGroup(true);
            });
          }
        } else {
          final g = _groups[_keyboardGroupIndex];
          final items = g.items;
          final currentIndex = items.indexWhere((e) => e.key == _keyboardPhotoKey);
          if (currentIndex != -1 && currentIndex < items.length - 1) {
            setState(() {
              _keyboardPhotoKey = items[currentIndex + 1].key;
            });
          }
        }
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _runSortAndProcess() async {
    // 処理中のファイルを除外した仕分け対象を抽出
    final targets = _selectedSortFolders.entries
        .where((e) => !_processingKeys.contains(e.key))
        .toList();

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('仕分け先が設定されている（未処理の）写真がありません。')),
      );
      return;
    }

    final bool? isCopy = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('仕分け処理の実行'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('仕分け先が設定された ${targets.length} 枚の写真に対して処理を実行します。'),
              const SizedBox(height: 12),
              const Text('処理方法を選択してください：'),
              const SizedBox(height: 8),
              const Text('• 移動：ファイルを新しいフォルダに移動します（元の場所からは削除されます）。', style: TextStyle(fontSize: 12)),
              const Text('• コピー：ファイルを新しいフォルダに複製します（元の場所にも残ります）。', style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false), // 移動
              child: const Text('移動する'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true), // コピー
              child: const Text('コピーする'),
            ),
          ],
        );
      },
    );

    if (isCopy == null) return;

    // 念のため、実行直前に再度処理中のキーが混入していないかダブルチェック
    final finalTargets = targets
        .where((e) => !_processingKeys.contains(e.key))
        .toList();

    if (finalTargets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('選択された写真はすでに処理中です。')),
        );
      }
      return;
    }

    final Map<String, String> currentSortMap = {
      for (final e in finalTargets) e.key: e.value
    };

    setState(() {
      _processingKeys.addAll(currentSortMap.keys);
      _selectedSortFolders.removeWhere((key, _) => currentSortMap.containsKey(key));
    });

    final taskId = 'sort_${DateTime.now().millisecondsSinceEpoch}';
    final task = _BackgroundTask(
      id: taskId,
      title: '写真を${isCopy ? "コピー" : "移動"}中',
      total: currentSortMap.length,
    );

    setState(() {
      _backgroundTasks.add(task);
    });

    // バックグラウンドで実行
    _executeSortInBackground(task, currentSortMap, isCopy);
  }

  Future<void> _executeSortInBackground(
    _BackgroundTask task,
    Map<String, String> currentSortMap,
    bool isCopy,
  ) async {
    final entries = currentSortMap.keys
        .map((k) => _entryByKey[k])
        .whereType<PhotoEntry>()
        .toList();

    try {
      final result = await SortService.executeSort(
        sortMap: currentSortMap,
        entries: entries,
        isCopy: isCopy,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              task.progress = total <= 0 ? 0.0 : done / total;
              task.statusText = '処理中... ($done / $total)';
            });
          }
        },
      );

      final entryMapByPath = {for (final e in _entryByKey.values) e.filePath: e};
      final failedKeys = result.failedFiles
          .map((path) => entryMapByPath[path]?.key)
          .whereType<String>()
          .toSet();

      final successKeys = currentSortMap.keys
          .where((key) => !failedKeys.contains(key))
          .toSet();

      if (mounted) {
        setState(() {
          _processingKeys.removeAll(currentSortMap.keys);

          if (!isCopy && successKeys.isNotEmpty) {
            for (final key in successKeys) {
              for (var i = 0; i < _groups.length; i++) {
                final g = _groups[i];
                if (g.items.any((item) => item.key == key)) {
                  final newItems = g.items.where((item) => item.key != key).toList();
                  _groups[i] = g.copyWith(items: newItems);
                }
              }
            }
            _groups.removeWhere((g) => g.items.isEmpty);
            _syncEntryByKey();
            _sortedPortraitItems = null;
            _clampKeyboardIndices();
          }
        });

        if (result.failedFiles.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${result.successCount} 枚の写真を${isCopy ? "コピー" : "移動"}しました。'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          showDialog(
            context: context,
            builder: (context) {
              return AlertDialog(
                title: const Text('仕分け完了（一部失敗）'),
                content: Text('${result.successCount} 枚の処理は成功しましたが、${result.failedFiles.length} 枚の処理に失敗しました。\n\n原因の例: ファイルのロック、容量不足、権限の喪失など。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('確認'),
                  ),
                ],
              );
            },
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processingKeys.removeAll(currentSortMap.keys);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('処理中にシステムエラーが発生しました: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _backgroundTasks.removeWhere((t) => t.id == task.id);
        });
      }
    }
  }

  Future<void> _addNewFolder(BuildContext context, String key, bool isGrid) async {
    if (_customFolders.length >= 10) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('フォルダは最大10個までしか作成できません。')),
        );
      }
      return;
    }

    final textController = TextEditingController();
    final newFolder = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('新規フォルダの作成'),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'フォルダ名を入力してください',
            ),
            maxLength: 30,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () {
                final val = textController.text.trim();
                if (val.isNotEmpty) {
                  Navigator.of(context).pop(val);
                }
              },
              child: const Text('作成'),
            ),
          ],
        );
      },
    );
    textController.dispose();

    if (newFolder != null && newFolder.isNotEmpty) {
      final RegExp invalidChars = RegExp(r'[<>:"/\\|?*]');
      if (invalidChars.hasMatch(newFolder)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('フォルダ名に使用できない文字が含まれています。')),
          );
        }
        return;
      }

      if (_customFolders.contains(newFolder)) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('同名のフォルダが既に存在します。')),
          );
        }
        return;
      }

      setState(() {
        _customFolders.add(newFolder);
        _selectedSortFolders[key] = newFolder;
      });
    }
  }

  Widget _buildSortFolderButtonForGrid(String key, ThemeData theme) {
    final sortFolder = _selectedSortFolders[key];
    final hasFolder = sortFolder != null;
    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String?>(
        tooltip: 'フォルダに仕分ける',
        onSelected: (folder) {
          if (folder == '__NEW_FOLDER__') {
            _addNewFolder(context, key, true);
          } else if (folder == null) {
            setState(() {
              _selectedSortFolders.remove(key);
            });
          } else {
            setState(() {
              _selectedSortFolders[key] = folder;
            });
          }
        },
        offset: const Offset(0, 30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hasFolder ? getFolderColor(sortFolder, _customFolders) : Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasFolder ? Icons.folder : Icons.folder_open,
                size: 16,
                color: Colors.white,
              ),
              if (hasFolder) ...[
                const SizedBox(width: 4),
                Text(
                  sortFolder,
                  style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ],
          ),
        ),
        itemBuilder: (context) {
          return [
            PopupMenuItem<String?>(
              value: '__NEW_FOLDER__',
              child: Row(
                children: [
                  Icon(Icons.create_new_folder, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('新規フォルダを追加...'),
                ],
              ),
            ),
            PopupMenuItem<String?>(
              value: null,
              child: Row(
                children: [
                  Icon(Icons.folder_off, size: 16, color: theme.hintColor),
                  const SizedBox(width: 8),
                  const Text('仕分けを解除'),
                ],
              ),
            ),
            ..._customFolders.map((folder) {
              return PopupMenuItem<String?>(
                value: folder,
                child: Row(
                  children: [
                    Icon(Icons.folder, size: 16, color: getFolderColor(folder, _customFolders)),
                    const SizedBox(width: 8),
                    Text(folder),
                  ],
                ),
              );
            }),
          ];
        },
      ),
    );
  }

  void _openLoupe(List<PhotoEntry> items) {
    if (items.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoupeScreen(
          items: items,
          scores: items.map((e) => e.sharpness).toList(),
          isBests: items.map((e) {
            for (final g in _groups) {
              if (g.items.any((item) => item.key == e.key)) {
                return e.key == g.bestKey;
              }
            }
            return false;
          }).toList(),
          initialSelectedForDelete: _selectedForDelete,
          onToggleDelete: (k, val) {
            setState(() {
              if (val) {
                _selectedForDelete.add(k);
              } else {
                _selectedForDelete.remove(k);
              }
            });
          },
          onSetBest: (k) {
            setState(() {
              for (var i = 0; i < _groups.length; i++) {
                final g = _groups[i];
                if (g.items.any((item) => item.key == k)) {
                  _groups[i] = g.copyWith(bestKey: k);
                  break;
                }
              }
            });
          },
        ),
      ),
    );
  }

  void _showKeyboardShortcutsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.keyboard_command_key_rounded, size: 24),
              SizedBox(width: 8),
              Text('キーボード操作ガイド'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('本画面およびルーペ画面は、キーボードで高速に操作可能です。'),
              const SizedBox(height: 16),
              _buildShortcutRow('← / →', '同じグループ内での写真選択の移動 / ルーペのペイン移動'),
              _buildShortcutRow('↑ / ↓', 'グループ間の移動'),
              _buildShortcutRow('1 〜 4', 'ルーペ画面でペインを直接選択'),
              _buildShortcutRow('Space', '選択中の写真を削除候補に設定 / 解除'),
              _buildShortcutRow('Enter', '選択中の写真をルーペ（詳細比較）で表示'),
              _buildShortcutRow('B', '選択中の写真をこのグループの「Best」に設定'),
              _buildShortcutRow('L', '選択中の写真をルーペ比較対象に設定 / 解除（最大4枚）'),
              _buildShortcutRow('I', '情報HUDモード切り替え（コンパクト ⇄ 詳細 ⇄ クリーン）'),
              _buildShortcutRow('H', 'ヒストグラム表示のオン / オフ'),
              _buildShortcutRow('M', 'フォーカスマスクのオン / オフ'),
              _buildShortcutRow('Z', 'ピント位置へズーム / リセット（ダブルタップでも可）'),
              _buildShortcutRow('S', '連動拡大のオン / オフ切り替え（ルーペ画面）'),
              _buildShortcutRow('Esc', 'ルーペ画面を閉じる / 選択解除'),
            ],
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

  Widget _buildShortcutRow(String keyStroke, String description) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 80,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: Text(
              keyStroke,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              description,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitBody(BuildContext context, List<PhotoEntry> portraitItems, bool isWide, double width, int crossAxisCount) {
    Widget buildItem(int index) {
      final e = portraitItems[index];
      final t = e.capturedAt;
      final timeStr = t == null
          ? ''
          : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      final eyeText = e.portrait.bothEyesDetected
          ? '目閉じなし'
          : (e.portrait.eyesClosed ? '目閉じ' : '');

      final loupeSelected = _loupeSelection.contains(e.key);
      final selectedForDelete = _selectedForDelete.contains(e.key);
      final isKeyboardFocused = index == _keyboardPortraitIndex;
      final theme = Theme.of(context);
      final sortFolder = _selectedSortFolders[e.key];
      final hasFolder = sortFolder != null;

      return InkWell(
        onTap: () {
          setState(() {
            _keyboardPortraitIndex = index;
            if (selectedForDelete) {
              _selectedForDelete.remove(e.key);
            } else {
              _selectedForDelete.add(e.key);
            }
          });
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: selectedForDelete
                ? theme.colorScheme.error.withValues(alpha: 0.08)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isKeyboardFocused
                  ? theme.colorScheme.primary
                  : (selectedForDelete
                      ? theme.colorScheme.error
                      : (hasFolder
                          ? getFolderColor(sortFolder, _customFolders)
                          : (loupeSelected
                              ? theme.colorScheme.primary.withValues(alpha: 0.5)
                              : theme.dividerColor.withValues(alpha: 0.12)))),
              width: isKeyboardFocused ? 2.5 : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
                child: Stack(
                  children: [
                    Opacity(
                      opacity: selectedForDelete ? 0.45 : 1.0,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          selectedForDelete ? Colors.grey : Colors.transparent,
                          BlendMode.saturation,
                        ),
                        child: Image.memory(
                          e.displayBytes,
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                    if (loupeSelected)
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${_loupeSelection.indexOf(e.key) + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    // Checkbox (Top Right)
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Checkbox(
                        value: selectedForDelete,
                        onChanged: (v) {
                          setState(() {
                            _keyboardPortraitIndex = index;
                            if (v == true) {
                              _selectedForDelete.add(e.key);
                            } else {
                              _selectedForDelete.remove(e.key);
                            }
                          });
                        },
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        side: const BorderSide(color: Colors.white, width: 1.5),
                      ),
                    ),
                    // Loupe Button (Bottom Right)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _keyboardPortraitIndex = index;
                              if (loupeSelected) {
                                _loupeSelection.remove(e.key);
                              } else {
                                if (_loupeSelection.length >= 4) {
                                  _loupeSelection.removeAt(0);
                                }
                                _loupeSelection.add(e.key);
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: loupeSelected
                                  ? theme.colorScheme.primary
                                  : Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              loupeSelected ? Icons.zoom_in_map : Icons.zoom_in,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Folder Button (Bottom Left)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: _buildSortFolderButtonForGrid(e.key, theme),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timeStr.isEmpty ? '（時刻不明）' : timeStr,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '鮮明度: ${e.sharpness.toStringAsFixed(0)}（顔ROI: ${e.portrait.faceSharpness.toStringAsFixed(0)}）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (eyeText.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          eyeText,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: e.portrait.bothEyesDetected
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFFDC2626),
                              ),
                        ),
                      ],
                      if ((e.portrait.eyeOpenAvg ?? -1.0) >= 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '目開き平均: ${(e.portrait.eyeOpenAvg ?? 0.0).toStringAsFixed(2)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
      );
    }

    Widget buildGridItem(int index) {
      final e = portraitItems[index];
      final t = e.capturedAt;
      final timeStr = t == null
          ? ''
          : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      final eyeText = e.portrait.bothEyesDetected
          ? '目閉じなし'
          : (e.portrait.eyesClosed ? '目閉じ' : '');

      final loupeSelected = _loupeSelection.contains(e.key);
      final selectedForDelete = _selectedForDelete.contains(e.key);
      final isKeyboardFocused = index == _keyboardPortraitIndex;
      final theme = Theme.of(context);
      final sortFolder = _selectedSortFolders[e.key];
      final hasFolder = sortFolder != null;

      return InkWell(
        onTap: () {
          setState(() {
            _keyboardPortraitIndex = index;
            if (selectedForDelete) {
              _selectedForDelete.remove(e.key);
            } else {
              _selectedForDelete.add(e.key);
            }
          });
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: selectedForDelete
                ? theme.colorScheme.error.withValues(alpha: 0.08)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isKeyboardFocused
                  ? theme.colorScheme.primary
                  : (selectedForDelete
                      ? theme.colorScheme.error
                      : (hasFolder
                          ? getFolderColor(sortFolder, _customFolders)
                          : (loupeSelected
                              ? theme.colorScheme.primary.withValues(alpha: 0.5)
                              : theme.dividerColor.withValues(alpha: 0.12)))),
              width: isKeyboardFocused ? 2.5 : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    )
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(
                        opacity: selectedForDelete ? 0.45 : 1.0,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            selectedForDelete ? Colors.grey : Colors.transparent,
                            BlendMode.saturation,
                          ),
                          child: Image.memory(
                            e.displayBytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                      if (loupeSelected)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${_loupeSelection.indexOf(e.key) + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      // Checkbox (Top Right)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Checkbox(
                          value: selectedForDelete,
                          onChanged: (v) {
                            setState(() {
                              _keyboardPortraitIndex = index;
                              if (v == true) {
                                _selectedForDelete.add(e.key);
                              } else {
                                _selectedForDelete.remove(e.key);
                              }
                            });
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          side: const BorderSide(color: Colors.white, width: 1.5),
                        ),
                      ),
                      // Loupe Button (Bottom Right)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _keyboardPortraitIndex = index;
                                if (loupeSelected) {
                                  _loupeSelection.remove(e.key);
                                } else {
                                  if (_loupeSelection.length >= 4) {
                                    _loupeSelection.removeAt(0);
                                  }
                                  _loupeSelection.add(e.key);
                                }
                              });
                            },
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: loupeSelected
                                    ? theme.colorScheme.primary
                                    : Colors.black.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                loupeSelected ? Icons.zoom_in_map : Icons.zoom_in,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Folder Button (Bottom Left)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: _buildSortFolderButtonForGrid(e.key, theme),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          timeStr.isEmpty ? '（時刻不明）' : timeStr,
                          style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          'S: ${e.sharpness.toStringAsFixed(0)}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '顔ROI: ${e.portrait.faceSharpness.toStringAsFixed(0)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                    if (eyeText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        eyeText,
                        style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: e.portrait.bothEyesDetected
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFDC2626),
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isMobile = width < 600;

    if (isWide) {
      return GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.82,
        ),
        itemCount: portraitItems.length,
        itemBuilder: (context, i) => buildGridItem(i),
      );
    } else if (isMobile) {
      return GridView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 0.82,
        ),
        itemCount: portraitItems.length,
        itemBuilder: (context, index) {
          return buildGridItem(index);
        },
      );
    } else {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: portraitItems.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: buildItem(index),
          );
        },
      );
    }
  }

  Widget _buildGroupBody(BuildContext context, bool isWide, double width, int crossAxisCount) {
    Widget buildItem(int index) {
      final g = _groups[index];
      final isKeyboardGroupFocused = index == _keyboardGroupIndex;

      return _ExpandableGroupCard(
        group: g,
        selectedForDelete: _selectedForDelete,
        onToggleDelete: (key, v) {
          setState(() {
            if (v) {
              _selectedForDelete.add(key);
            } else {
              _selectedForDelete.remove(key);
            }
          });
        },
        loupeSelection: _loupeSelection,
        onToggleLoupe: (key) {
          setState(() {
            if (_loupeSelection.contains(key)) {
              _loupeSelection.remove(key);
            } else {
              if (_loupeSelection.length >= 4) {
                _loupeSelection.removeAt(0);
              }
              _loupeSelection.add(key);
            }
          });
        },
        onSelectBestOnly: () {
          setState(() {
            for (final item in g.items) {
              if (item.key != g.bestKey) {
                _selectedForDelete.add(item.key);
              } else {
                _selectedForDelete.remove(item.key);
              }
            }
          });
        },
        isKeyboardGroupFocused: isKeyboardGroupFocused,
        keyboardPhotoKey: isKeyboardGroupFocused ? _keyboardPhotoKey : null,
        onPhotoTileFocused: (key) {
          setState(() {
            _keyboardGroupIndex = index;
            _keyboardPhotoKey = key;
          });
        },
        selectedSortFolders: _selectedSortFolders,
        customFolders: _customFolders,
        processingKeys: _processingKeys,
        onSortFolderChanged: (key, folder) {
          if (folder == '__NEW_FOLDER__') {
            _addNewFolder(context, key, false);
          } else {
            setState(() {
              if (folder == null) {
                _selectedSortFolders.remove(key);
              } else {
                _selectedSortFolders[key] = folder;
              }
            });
          }
        },
      );
    }

    if (isWide) {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: (_groups.length / crossAxisCount).ceil(),
        itemBuilder: (context, index) {
          final children = <Widget>[];
          for (int i = 0; i < crossAxisCount; i++) {
            final itemIndex = index * crossAxisCount + i;
            if (itemIndex < _groups.length) {
              children.add(Expanded(child: buildItem(itemIndex)));
            } else {
              children.add(const Expanded(child: SizedBox.shrink()));
            }
            if (i < crossAxisCount - 1) {
              children.add(const SizedBox(width: 16));
            }
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          );
        },
      );
    } else {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: _groups.length,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: buildItem(index),
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 800;
    final isMobile = size.width < 600;
    final crossAxisCount = size.width >= 800 ? 2 : 1;

    final isPortrait = widget.detectionMode == DetectionMode.portrait;
    final portraitItems = _getPortraitItems();

    final bool canSort = _selectedSortFolders.keys.any((k) => !_processingKeys.contains(k));
    final bool canDelete = _selectedForDelete.any((k) => !_processingKeys.contains(k));
    final bool canExport = _backgroundTasks.isEmpty;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainer.withValues(alpha: 0.3),
        appBar: AppBar(
          title: isMobile
              ? const Text(
                  '整理・比較',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('整理・比較'),
                    Text(
                      isPortrait
                          ? '写真: ${portraitItems.length} / 顔あり: ${portraitItems.where((e) => e.portrait.hasFace).length} / 削除候補: $_selectedCount'
                          : 'グループ: ${_groups.length} / 削除候補: $_selectedCount',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ),
          actions: [
            if (!Platform.isAndroid && !Platform.isIOS)
              IconButton(
                tooltip: 'キーボード操作ガイド',
                icon: const Icon(Icons.keyboard_command_key_rounded),
                onPressed: () => _showKeyboardShortcutsDialog(context),
              ),
            if (!isPortrait)
              isMobile
                  ? IconButton(
                      tooltip: 'Bestのみ保存',
                      icon: const Icon(Icons.folder_shared),
                      onPressed: canExport ? _exportBestShots : null,
                      color: colorScheme.primary,
                    )
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton.icon(
                        onPressed: canExport ? _exportBestShots : null,
                        icon: const Icon(Icons.folder_shared, size: 20),
                        label: const Text('Bestのみ保存'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colorScheme.primaryContainer,
                          foregroundColor: colorScheme.onPrimaryContainer,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                      ),
                    ),
            isMobile
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Badge(
                      label: Text('${_selectedSortFolders.length}'),
                      isLabelVisible: _selectedSortFolders.isNotEmpty,
                      child: IconButton(
                        tooltip: '仕分け実行',
                        icon: const Icon(Icons.folder_copy),
                        onPressed: canSort ? _runSortAndProcess : null,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Badge(
                      label: Text('${_selectedSortFolders.length}'),
                      isLabelVisible: _selectedSortFolders.isNotEmpty,
                      child: FilledButton.icon(
                        onPressed: canSort ? _runSortAndProcess : null,
                        icon: const Icon(Icons.folder_copy, size: 20),
                        label: const Text('仕分け実行'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colorScheme.primaryContainer,
                          foregroundColor: colorScheme.onPrimaryContainer,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                      ),
                    ),
                  ),
            if (_loupeSelection.isNotEmpty)
              IconButton(
                tooltip: 'ルーペ選択を解除',
                onPressed: () => setState(_loupeSelection.clear),
                icon: const Icon(Icons.deselect),
              ),
            isMobile
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Badge(
                      label: Text('${_loupeSelection.length}'),
                      isLabelVisible: _loupeSelection.isNotEmpty,
                      child: IconButton(
                        tooltip: 'ルーペ比較',
                        icon: const Icon(Icons.zoom_in),
                        onPressed: _loupeSelection.isNotEmpty
                            ? () {
                                final items = _loupeSelection
                                    .map((k) => _entryByKey[k])
                                    .whereType<PhotoEntry>()
                                    .toList();
                                _openLoupe(items);
                              }
                            : null,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton.icon(
                      onPressed: _loupeSelection.isNotEmpty
                          ? () {
                              final items = _loupeSelection
                                  .map((k) => _entryByKey[k])
                                  .whereType<PhotoEntry>()
                                  .toList();
                              _openLoupe(items);
                            }
                          : null,
                      icon: const Icon(Icons.zoom_in, size: 20),
                      label: Text('ルーペ (${_loupeSelection.length}/4)'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                    ),
                  ),
            isMobile
                ? Padding(
                    padding: const EdgeInsets.only(left: 8, right: 12),
                    child: Badge(
                      label: Text('$_selectedCount'),
                      isLabelVisible: _selectedCount > 0,
                      backgroundColor: colorScheme.error,
                      textColor: colorScheme.onError,
                      child: IconButton(
                        tooltip: 'ゴミ箱へ',
                        icon: Icon(
                          Icons.delete_outline,
                          color: _selectedCount > 0 ? colorScheme.error : null,
                        ),
                        onPressed: canDelete
                            ? _reviewAndDelete
                            : null,
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: FilledButton.icon(
                      onPressed: canDelete
                          ? _reviewAndDelete
                          : null,
                      icon: const Icon(Icons.delete_outline, size: 20),
                      label: const Text('ゴミ箱へ'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.error,
                        foregroundColor: colorScheme.onError,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                    ),
                  ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: isPortrait
                  ? _buildPortraitBody(context, portraitItems, isWide, size.width, crossAxisCount)
                  : _buildGroupBody(context, isWide, size.width, crossAxisCount),
            ),
            if (_backgroundTasks.isNotEmpty)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: _buildBottomProgressOverlay(colorScheme),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomProgressOverlay(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final task in _backgroundTasks) ...[
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        task.statusText,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 60,
                  child: LinearProgressIndicator(
                    value: task.progress,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  ),
                ),
              ],
            ),
            if (task != _backgroundTasks.last)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Divider(color: Colors.white10, height: 1),
              ),
          ],
        ],
      ),
    );
  }
}
