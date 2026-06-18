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
  late final Set<String> _selectedForDelete;
  bool _deleting = false;
  final List<String> _loupeSelection = [];

  // 仕分け用の状態変数
  final Map<String, String> _selectedSortFolders = {};
  final List<String> _customFolders = [];
  bool _sorting = false;

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

    _entryByKey = {
      for (final g in widget.groups)
        for (final e in g.items) e.key: e,
    };
    _selectedForDelete = {
      for (final g in widget.groups) ...g.deleteCandidateKeys,
    };

    // Initialize keyboard photo focus to the first bestKey
    if (widget.groups.isNotEmpty) {
      _keyboardPhotoKey = widget.groups.first.bestKey;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  int get _selectedCount => _selectedForDelete.length;

  Future<void> _exportBestShots() async {
    final selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return; // Cancelled

    setState(() {
      _deleting = true;
    });

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
      for (final group in widget.groups) {
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
      if (mounted) {
        setState(() {
          _deleting = false;
        });
      }
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
          items: targets.map((k) => _entryByKey[k]!).toList(),
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
            _entryByKey.remove(entry.key);
            for (final g in widget.groups) {
              g.items.removeWhere((item) => item.key == entry.key);
            }
          }
          widget.groups.removeWhere((g) => g.items.isEmpty);
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
    final portraitItems = isPortrait ? _entryByKey.values.toList() : const <PhotoEntry>[];
    
    if (isPortrait) {
      portraitItems.sort((a, b) {
        final fa = a.hasPortraitFace ? 0 : 1;
        final fb = b.hasPortraitFace ? 0 : 1;
        final faceCmp = fa.compareTo(fb);
        if (faceCmp != 0) return faceCmp;
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });
    }

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
          if (widget.groups.isNotEmpty && _keyboardGroupIndex < widget.groups.length - 1) {
            _keyboardGroupIndex++;
            final g = widget.groups[_keyboardGroupIndex];
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
            final g = widget.groups[_keyboardGroupIndex];
            if (g.items.isNotEmpty) {
              _keyboardPhotoKey = g.bestKey;
            }
            _scrollToActiveGroup(false);
          }
        }
      });
      return KeyEventResult.handled;
    }

    if (!isPortrait && widget.groups.isNotEmpty) {
      final g = widget.groups[_keyboardGroupIndex];
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
            g.bestKey = _keyboardPhotoKey!;
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
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LoupeScreen(
                items: items,
                scores: items.map((e) => e.sharpness).toList(),
                isBests: items.map((e) {
                  for (final g in widget.groups) {
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
                    for (final g in widget.groups) {
                      if (g.items.any((item) => item.key == k)) {
                        g.bestKey = k;
                        break;
                      }
                    }
                  });
                },
              ),
            ),
          );
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
          final g = widget.groups[_keyboardGroupIndex];
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
              _entryByKey.remove(key);
              for (final g in widget.groups) {
                g.items.removeWhere((item) => item.key == key);
              }
            }
            widget.groups.removeWhere((g) => g.items.isEmpty);
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
            color: hasFolder ? getFolderColor(sortFolder, _customFolders) : Colors.black.withOpacity(0.5),
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
              _buildShortcutRow('← / →', '同じグループ内での写真選択の移動'),
              _buildShortcutRow('↑ / ↓', 'グループ間の移動'),
              _buildShortcutRow('Space', '選択中の写真を削除候補（ゴミ箱マーク）に設定 / 解除'),
              _buildShortcutRow('Enter', '選択中の写真をルーペ（詳細比較）で表示'),
              _buildShortcutRow('B', '選択中の写真をこのグループの「Best」に設定'),
              _buildShortcutRow('L', '選択中の写真をルーペ比較対象に設定 / 解除（最大4枚）'),
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
      final eyeText = e.portraitBothEyesDetected
          ? '目閉じなし'
          : (e.portraitEyesClosed ? '目閉じ' : '');

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
                ? theme.colorScheme.error.withOpacity(0.08)
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
                              ? theme.colorScheme.primary.withOpacity(0.5)
                              : theme.dividerColor.withOpacity(0.12)))),
              width: isKeyboardFocused ? 2.5 : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.25),
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
                                  : Colors.black.withOpacity(0.5),
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
                        '鮮明度: ${e.sharpness.toStringAsFixed(0)}（顔ROI: ${e.portraitFaceSharpness.toStringAsFixed(0)}）',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (eyeText.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          eyeText,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: e.portraitBothEyesDetected
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFFDC2626),
                              ),
                        ),
                      ],
                      if (e.portraitEyeOpenAvg >= 0) ...[
                        const SizedBox(height: 2),
                        Text(
                          '目開き平均: ${e.portraitEyeOpenAvg.toStringAsFixed(2)}',
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
      final eyeText = e.portraitBothEyesDetected
          ? '目閉じなし'
          : (e.portraitEyesClosed ? '目閉じ' : '');

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
                ? theme.colorScheme.error.withOpacity(0.08)
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
                              ? theme.colorScheme.primary.withOpacity(0.5)
                              : theme.dividerColor.withOpacity(0.12)))),
              width: isKeyboardFocused ? 2.5 : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.25),
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
                                    : Colors.black.withOpacity(0.5),
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
                      '顔ROI: ${e.portraitFaceSharpness.toStringAsFixed(0)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                    ),
                    if (eyeText.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        eyeText,
                        style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: e.portraitBothEyesDetected
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
      final itemWidth = (width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
      return SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (int i = 0; i < portraitItems.length; i++)
              SizedBox(
                width: itemWidth,
                height: itemWidth / 0.82,
                child: buildGridItem(i),
              ),
          ],
        ),
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
      final g = widget.groups[index];
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
      final itemWidth = (width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
      return SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (int i = 0; i < widget.groups.length; i++)
              SizedBox(
                width: itemWidth,
                child: buildItem(i),
              ),
          ],
        ),
      );
    } else {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: widget.groups.length,
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
    final portraitItems = isPortrait ? _entryByKey.values.toList() : const <PhotoEntry>[];
    if (isPortrait) {
      portraitItems.sort((a, b) {
        final fa = a.hasPortraitFace ? 0 : 1;
        final fb = b.hasPortraitFace ? 0 : 1;
        final faceCmp = fa.compareTo(fb);
        if (faceCmp != 0) return faceCmp;
        final ta = a.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final tb = b.capturedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return ta.compareTo(tb);
      });
    }

    final bool canSort = _selectedSortFolders.keys.any((k) => !_processingKeys.contains(k));
    final bool canDelete = _selectedForDelete.any((k) => !_processingKeys.contains(k));
    final bool canExport = _backgroundTasks.isEmpty;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainer.withOpacity(0.3),
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
                          ? '写真: ${portraitItems.length} / 顔あり: ${portraitItems.where((e) => e.hasPortraitFace).length} / 削除候補: $_selectedCount'
                          : 'グループ: ${widget.groups.length} / 削除候補: $_selectedCount',
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
                                if (items.isEmpty) return;
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => LoupeScreen(
                                      items: items,
                                      scores: _loupeSelection
                                          .map((k) => _entryByKey[k])
                                          .whereType<PhotoEntry>()
                                          .map((e) => e.sharpness)
                                          .toList(),
                                      isBests: _loupeSelection
                                          .map((k) => _entryByKey[k])
                                          .whereType<PhotoEntry>()
                                          .map((e) {
                                            for (final g in widget.groups) {
                                              if (g.items.any((item) => item.key == e.key)) {
                                                return e.key == g.bestKey;
                                              }
                                            }
                                            return false;
                                          })
                                          .toList(),
                                      initialSelectedForDelete: _selectedForDelete,
                                      onToggleDelete: (key, val) {
                                        setState(() {
                                          if (val) {
                                            _selectedForDelete.add(key);
                                          } else {
                                            _selectedForDelete.remove(key);
                                          }
                                        });
                                      },
                                      onSetBest: (key) {
                                        setState(() {
                                          for (final g in widget.groups) {
                                            if (g.items.any((item) => item.key == key)) {
                                              g.bestKey = key;
                                              break;
                                            }
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                );
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
                              if (items.isEmpty) return;
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => LoupeScreen(
                                    items: items,
                                    scores: _loupeSelection
                                        .map((k) => _entryByKey[k])
                                        .whereType<PhotoEntry>()
                                        .map((e) => e.sharpness)
                                        .toList(),
                                    isBests: _loupeSelection
                                        .map((k) => _entryByKey[k])
                                        .whereType<PhotoEntry>()
                                        .map((e) {
                                          for (final g in widget.groups) {
                                            if (g.items.any((item) => item.key == e.key)) {
                                              return e.key == g.bestKey;
                                            }
                                          }
                                          return false;
                                        })
                                        .toList(),
                                    initialSelectedForDelete: _selectedForDelete,
                                    onToggleDelete: (key, val) {
                                      setState(() {
                                        if (val) {
                                          _selectedForDelete.add(key);
                                        } else {
                                          _selectedForDelete.remove(key);
                                        }
                                      });
                                    },
                                    onSetBest: (key) {
                                      setState(() {
                                        for (final g in widget.groups) {
                                          if (g.items.any((item) => item.key == key)) {
                                            g.bestKey = key;
                                            break;
                                          }
                                        }
                                      });
                                    },
                                  ),
                                ),
                              );
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
        color: Colors.black.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
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

class _BackgroundTask {
  _BackgroundTask({
    required this.id,
    required this.title,
    required this.total,
  });
  final String id;
  final String title;
  final int total;
  double progress = 0.0;
  String statusText = '準備中...';
}

class _ExpandableGroupCard extends StatelessWidget {
  const _ExpandableGroupCard({
    required this.group,
    required this.selectedForDelete,
    required this.onToggleDelete,
    required this.loupeSelection,
    required this.onToggleLoupe,
    required this.onSelectBestOnly,
    required this.isKeyboardGroupFocused,
    required this.keyboardPhotoKey,
    required this.onPhotoTileFocused,
    required this.selectedSortFolders,
    required this.onSortFolderChanged,
    required this.customFolders,
    required this.processingKeys,
  });

  final PhotoGroup group;
  final Set<String> selectedForDelete;
  final void Function(String key, bool selected) onToggleDelete;
  final List<String> loupeSelection;
  final void Function(String key) onToggleLoupe;
  final VoidCallback onSelectBestOnly;
  final bool isKeyboardGroupFocused;
  final String? keyboardPhotoKey;
  final ValueChanged<String> onPhotoTileFocused;
  final Map<String, String> selectedSortFolders;
  final void Function(String key, String? folder) onSortFolderChanged;
  final List<String> customFolders;
  final Set<String> processingKeys;

  @override
  Widget build(BuildContext context) {
    final best = group.items.firstWhere(
      (e) => e.key == group.bestKey,
      orElse: () => group.items.first,
    );
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surface,
      elevation: isKeyboardGroupFocused ? 4 : 0,
      shadowColor: isKeyboardGroupFocused ? theme.colorScheme.primary.withOpacity(0.3) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isKeyboardGroupFocused
              ? theme.colorScheme.primary
              : theme.dividerColor.withOpacity(0.12),
          width: isKeyboardGroupFocused ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isKeyboardGroupFocused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    group.id,
                    style: TextStyle(
                      color: isKeyboardGroupFocused
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        '${group.items.length} 枚',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: onSelectBestOnly,
                        icon: const Icon(Icons.playlist_remove, size: 16),
                        label: const Text('Best以外を削除候補に', style: TextStyle(fontSize: 11)),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                ),

                if (group.isBurst) ...[
                  const Icon(Icons.bolt, size: 14, color: Colors.orange),
                  const SizedBox(width: 4),
                  Text(
                    '連写',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '最高鮮明度: ${best.sharpness.toStringAsFixed(0)}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 140,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final e in group.items) ...[
                      SizedBox(
                        width: 140,
                        child: _PhotoTile(
                          bytes: e.displayBytes,
                          sharpness: e.sharpness,
                          exposureScore: e.exposureScore,
                          faceQualityScore: e.faceQualityScore,
                          exifText: e.exifText,
                          isBest: e.key == group.bestKey,
                          selectedForDelete: selectedForDelete.contains(e.key),
                          isProcessing: processingKeys.contains(e.key),
                          onChanged: (v) {
                            onPhotoTileFocused(e.key);
                            onToggleDelete(e.key, v);
                          },
                          loupeSelected: loupeSelection.contains(e.key),
                          onToggleLoupe: () {
                            onPhotoTileFocused(e.key);
                            onToggleLoupe(e.key);
                          },
                          isKeyboardFocused: e.key == keyboardPhotoKey,
                          sortFolder: selectedSortFolders[e.key],
                          customFolders: customFolders,
                          onSortFolderChanged: (folder) {
                            onPhotoTileFocused(e.key);
                            onSortFolderChanged(e.key, folder);
                          },
                        ),
                      ),
                      if (e != group.items.last) const SizedBox(width: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DeleteReviewScreen extends StatefulWidget {
  const DeleteReviewScreen({
    super.key,
    required this.items,
    required this.onRemoveFromDelete,
  });

  final List<PhotoEntry> items;
  final Function(String key) onRemoveFromDelete;

  @override
  State<DeleteReviewScreen> createState() => _DeleteReviewScreenState();
}

class _DeleteReviewScreenState extends State<DeleteReviewScreen> {
  final List<String> _loupeSelection = [];
  late List<PhotoEntry> _currentItems;

  @override
  void initState() {
    super.initState();
    _currentItems = List.from(widget.items);
  }

  void _toggleLoupe(String key) {
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('削除対象の確認'),
        actions: [
          IconButton(
            tooltip: 'ルーペ選択を解除',
            onPressed: _loupeSelection.isEmpty
                ? null
                : () => setState(_loupeSelection.clear),
            icon: const Icon(Icons.deselect),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _loupeSelection.isNotEmpty
                  ? () {
                      final items = _loupeSelection
                          .map(
                            (key) =>
                                _currentItems.firstWhere((e) => e.key == key),
                          )
                          .toList();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => LoupeScreen(
                            items: items,
                            scores: items.map((e) => e.sharpness).toList(),
                            isBests: List.generate(items.length, (_) => false),
                          ),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.zoom_in),
              label: Text('ルーペ (${_loupeSelection.length}/4)'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _currentItems.length,
              itemBuilder: (context, i) {
                final item = _currentItems[i];
                final isSelectedForLoupe = _loupeSelection.contains(item.key);

                return Stack(
                  children: [
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          item.displayBytes,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    // Selection overlay for loupe
                    if (isSelectedForLoupe)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 3,
                            ),
                            color: theme.colorScheme.primary.withOpacity(0.1),
                          ),
                        ),
                      ),
                    // Info overlay
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.sharpness.toStringAsFixed(0),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                    // Actions
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton.filled(
                        iconSize: 18,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                        ),
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () {
                          widget.onRemoveFromDelete(item.key);
                          setState(() {
                            _currentItems.remove(item);
                            _loupeSelection.remove(item.key);
                          });
                          if (_currentItems.isEmpty) {
                            Navigator.of(context).pop(false);
                          }
                        },
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: IconButton.filled(
                        iconSize: 18,
                        style: IconButton.styleFrom(
                          backgroundColor: isSelectedForLoupe
                              ? theme.colorScheme.primary
                              : Colors.black54,
                        ),
                        icon: Icon(
                          isSelectedForLoupe
                              ? Icons.zoom_in_map
                              : Icons.zoom_in,
                          color: Colors.white,
                        ),
                        onPressed: () => _toggleLoupe(item.key),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('キャンセル'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                      foregroundColor: theme.colorScheme.onError,
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text('${_currentItems.length}件をゴミ箱へ移動'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    required this.bytes,
    required this.sharpness,
    required this.exposureScore,
    required this.faceQualityScore,
    required this.exifText,
    required this.isBest,
    required this.selectedForDelete,
    required this.onChanged,
    required this.loupeSelected,
    required this.onToggleLoupe,
    required this.isKeyboardFocused,
    required this.sortFolder,
    required this.customFolders,
    required this.onSortFolderChanged,
    required this.isProcessing,
  });

  final Uint8List bytes;
  final double sharpness;
  final double exposureScore;
  final double faceQualityScore;
  final String exifText;
  final bool isBest;
  final bool selectedForDelete;
  final ValueChanged<bool> onChanged;
  final bool loupeSelected;
  final VoidCallback onToggleLoupe;
  final bool isKeyboardFocused;
  final String? sortFolder;
  final List<String> customFolders;
  final ValueChanged<String?> onSortFolderChanged;
  final bool isProcessing;

  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  bool _isHovered = false;

  Widget _buildSortFolderButtonForTile(ThemeData theme) {
    final sortFolder = widget.sortFolder;
    final hasFolder = sortFolder != null;
    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String?>(
        tooltip: 'フォルダに仕分ける',
        onSelected: (folder) {
          if (folder == '__NEW_FOLDER__') {
            widget.onSortFolderChanged(folder);
          } else {
            widget.onSortFolderChanged(folder);
          }
        },
        offset: const Offset(0, 30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hasFolder ? getFolderColor(sortFolder, widget.customFolders) : Colors.black.withOpacity(0.5),
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
            ...widget.customFolders.map((folder) {
              return PopupMenuItem<String?>(
                value: folder,
                child: Row(
                  children: [
                    Icon(Icons.folder, size: 16, color: getFolderColor(folder, widget.customFolders)),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedScale(
        scale: _isHovered ? 1.03 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: AnimatedPhysicalModel(
          shape: BoxShape.rectangle,
          borderRadius: BorderRadius.circular(16),
          elevation: _isHovered ? 6 : 1,
          color: Colors.transparent,
          shadowColor: Colors.black.withOpacity(0.3),
          duration: const Duration(milliseconds: 150),
          child: IgnorePointer(
            ignoring: widget.isProcessing,
            child: InkWell(
              onTap: () => widget.onChanged(!widget.selectedForDelete),
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  // Image and its clipping
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Opacity(
                        opacity: widget.selectedForDelete ? 0.45 : 1.0,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            widget.selectedForDelete ? Colors.grey : Colors.transparent,
                            BlendMode.saturation,
                          ),
                          child: Image.memory(
                            widget.bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Selection Overlay (Border) - Placed outside ClipRRect to avoid clipping
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: widget.isKeyboardFocused
                              ? Border.all(color: colorScheme.primary, width: 3)
                              : (widget.selectedForDelete
                                  ? Border.all(color: colorScheme.error, width: 3)
                                  : (widget.sortFolder != null
                                      ? Border.all(color: getFolderColor(widget.sortFolder!, widget.customFolders), width: 3)
                                      : Border.all(
                                          color: _isHovered
                                              ? Colors.white.withOpacity(0.4)
                                              : Colors.white.withOpacity(0.1),
                                          width: _isHovered ? 1.5 : 1,
                                        ))),
                          boxShadow: widget.isKeyboardFocused
                              ? [
                                  BoxShadow(
                                    color: colorScheme.primary.withOpacity(0.5),
                                    blurRadius: 10,
                                    spreadRadius: 1.5,
                                  )
                                ]
                              : null,
                          color: widget.selectedForDelete
                              ? colorScheme.error.withOpacity(0.1)
                              : Colors.transparent,
                        ),
                      ),
                    ),
                  ),

                  // Badges (Top Left)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Row(
                      children: [
                        if (widget.isBest)
                          const _Badge(label: 'Best', color: Color(0xFF22C55E)),
                        if (!widget.isBest)
                          _Badge(
                            label: widget.sharpness.toStringAsFixed(0),
                            color: Colors.black.withOpacity(0.6),
                          ),
                      ],
                    ),
                  ),

                  // Checkbox (Top Right)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: Checkbox(
                      value: widget.selectedForDelete,
                      onChanged: (v) => widget.onChanged(v ?? false),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      side: const BorderSide(color: Colors.white, width: 1.5),
                    ),
                  ),

                  // EXIF Overlay (Bottom)
                  if (widget.exifText.isNotEmpty)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 34,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: BackdropFilter(
                          filter: ColorFilter.mode(
                            Colors.black.withOpacity(0.4),
                            BlendMode.srcOver,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            child: Text(
                              widget.exifText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                  // Loupe Button (Bottom Right)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: widget.onToggleLoupe,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: widget.loupeSelected
                                ? colorScheme.primary
                                : Colors.black.withOpacity(0.5),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.loupeSelected ? Icons.zoom_in_map : Icons.zoom_in,
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
                    child: _buildSortFolderButtonForTile(theme),
                  ),

                  // Processing Overlay
                  if (widget.isProcessing)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

Color getFolderColor(String folder, List<String> customFolders) {
  final index = customFolders.indexOf(folder);
  if (index < 0) return Colors.grey;

  // 10 distinct, pleasant colors for our folders
  const colors = [
    Color(0xFFEF4444), // Red
    Color(0xFFF97316), // Orange
    Color(0xFFFBBF24), // Amber/Yellow
    Color(0xFF10B981), // Emerald/Green
    Color(0xFF06B6D4), // Cyan
    Color(0xFF3B82F6), // Blue
    Color(0xFF6366F1), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFD946EF), // Magenta
    Color(0xFF64748B), // Slate/Grey
  ];

  return colors[index % colors.length];
}
