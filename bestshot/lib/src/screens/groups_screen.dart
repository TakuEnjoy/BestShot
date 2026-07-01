import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/photo_entry.dart';
import '../models/photo_group.dart';
import '../services/analysis/analysis_types.dart';
import 'groups/groups_view_model.dart';
import 'groups/widgets/group_card.dart';
import 'groups/widgets/bottom_progress_overlay.dart';
import 'groups/widgets/delete_review_screen.dart';
import 'groups/widgets/photo_tile.dart' show getFolderColor;
import 'loupe_screen.dart';

final groupsViewModelProvider = Provider.autoDispose
    .family<GroupsViewModel, List<PhotoGroup>>((ref, groups) {
      final vm = GroupsViewModel(groups);
      ref.onDispose(vm.dispose);
      return vm;
    });

class GroupsScreen extends ConsumerStatefulWidget {
  const GroupsScreen({
    super.key,
    required this.groups,
    required this.detectionMode,
  });

  final List<PhotoGroup> groups;
  final DetectionMode detectionMode;

  @override
  ConsumerState<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends ConsumerState<GroupsScreen> {
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _scrollController = ScrollController();

    // Request focus after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _exportBestShots(GroupsViewModel vm) async {
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
      final count = await vm.exportBestShots(selectedDirectory);

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
    }
  }

  Future<void> _reviewAndDelete(GroupsViewModel vm) async {
    final targets = vm.selectedForDelete
        .where((k) => !vm.processingKeys.contains(k))
        .toList();

    if (targets.isEmpty) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DeleteReviewScreen(
          items: targets.map((k) => vm.entryByKey[k]!).toList(),
          onRemoveFromDelete: (key) {
            vm.toggleDeleteSelection(key);
          },
        ),
      ),
    );

    if (result == true) {
      final finalTargets = targets
          .where((k) => !vm.processingKeys.contains(k))
          .toList();

      if (finalTargets.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('選択された写真はすでに処理中です。')));
        }
        return;
      }

      vm.addProcessingKeys(finalTargets);
      vm.removeKeysFromSelection(finalTargets);

      final taskId = 'delete_${DateTime.now().millisecondsSinceEpoch}';
      final task = BackgroundTask(
        id: taskId,
        title: 'ゴミ箱へ移動中',
        total: finalTargets.length,
      );

      vm.addTask(task);

      vm.executeDeleteInBackground(
        task,
        finalTargets,
        (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('削除失敗: $error')));
          }
        },
        () {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('ゴミ箱へ移動しました')));
          }
        },
      );
    }
  }

  void _scrollToActiveGroup(GroupsViewModel vm, bool isPortrait) {
    if (!_scrollController.hasClients) return;
    final size = MediaQuery.of(context).size;
    final isWide = size.width >= 800;
    final isMobile = size.width < 600;
    final crossAxisCount = size.width >= 800 ? 2 : 1;

    if (isPortrait) {
      double targetOffset;
      if (isWide) {
        final itemWidth =
            (size.width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
        final itemHeight = itemWidth / 0.82 + 16;
        final rowIndex = vm.keyboardPortraitIndex ~/ crossAxisCount;
        targetOffset = rowIndex * itemHeight;
      } else if (isMobile) {
        final itemWidth = (size.width - 24 - 12) / 2;
        final itemHeight = itemWidth / 0.82 + 12;
        final rowIndex = vm.keyboardPortraitIndex ~/ 2;
        targetOffset = rowIndex * itemHeight;
      } else {
        targetOffset = vm.keyboardPortraitIndex * 130.0;
      }
      final currentOffset = _scrollController.offset;
      final viewHeight = size.height;
      if (targetOffset < currentOffset ||
          targetOffset > currentOffset + viewHeight - 250) {
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    } else {
      final targetOffset = vm.keyboardGroupIndex * 220.0;
      final currentOffset = _scrollController.offset;
      final viewHeight = size.height;
      if (targetOffset < currentOffset ||
          targetOffset > currentOffset + viewHeight - 300) {
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event, GroupsViewModel vm) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isPortrait = widget.detectionMode == DetectionMode.portrait;
    final portraitItems = isPortrait
        ? vm.entryByKey.values.toList()
        : const <PhotoEntry>[];

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

    final bool isEditKey =
        key == LogicalKeyboardKey.keyB ||
        key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.digit1 ||
        key == LogicalKeyboardKey.numpad1 ||
        key == LogicalKeyboardKey.digit2 ||
        key == LogicalKeyboardKey.numpad2 ||
        key == LogicalKeyboardKey.digit3 ||
        key == LogicalKeyboardKey.numpad3 ||
        key == LogicalKeyboardKey.digit4 ||
        key == LogicalKeyboardKey.numpad4 ||
        key == LogicalKeyboardKey.digit5 ||
        key == LogicalKeyboardKey.numpad5 ||
        key == LogicalKeyboardKey.digit6 ||
        key == LogicalKeyboardKey.numpad6 ||
        key == LogicalKeyboardKey.digit7 ||
        key == LogicalKeyboardKey.numpad7 ||
        key == LogicalKeyboardKey.digit8 ||
        key == LogicalKeyboardKey.numpad8 ||
        key == LogicalKeyboardKey.digit9 ||
        key == LogicalKeyboardKey.numpad9 ||
        key == LogicalKeyboardKey.digit0 ||
        key == LogicalKeyboardKey.numpad0;

    if (isEditKey) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty
                ? portraitItems[vm.keyboardPortraitIndex].key
                : null)
          : vm.keyboardPhotoKey;
      if (targetKey != null && vm.processingKeys.contains(targetKey)) {
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      if (isPortrait) {
        if (portraitItems.isNotEmpty &&
            vm.keyboardPortraitIndex < portraitItems.length - 1) {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            vm.keyboardPhotoKey,
            portraitIndex: vm.keyboardPortraitIndex + 1,
          );
          _scrollToActiveGroup(vm, true);
        }
      } else {
        if (vm.groups.isNotEmpty &&
            vm.keyboardGroupIndex < vm.groups.length - 1) {
          final g = vm.groups[vm.keyboardGroupIndex + 1];
          final photoKey = g.items.isNotEmpty ? g.bestKey : null;
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex + 1,
            photoKey,
            portraitIndex: vm.keyboardPortraitIndex,
          );
          _scrollToActiveGroup(vm, false);
        }
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      if (isPortrait) {
        if (vm.keyboardPortraitIndex > 0) {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            vm.keyboardPhotoKey,
            portraitIndex: vm.keyboardPortraitIndex - 1,
          );
          _scrollToActiveGroup(vm, true);
        }
      } else {
        if (vm.keyboardGroupIndex > 0) {
          final g = vm.groups[vm.keyboardGroupIndex - 1];
          final photoKey = g.items.isNotEmpty ? g.bestKey : null;
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex - 1,
            photoKey,
            portraitIndex: vm.keyboardPortraitIndex,
          );
          _scrollToActiveGroup(vm, false);
        }
      }
      return KeyEventResult.handled;
    }

    if (!isPortrait && vm.groups.isNotEmpty) {
      final g = vm.groups[vm.keyboardGroupIndex];
      final items = g.items;
      final currentIndex = items.indexWhere(
        (e) => e.key == vm.keyboardPhotoKey,
      );

      if (key == LogicalKeyboardKey.arrowRight) {
        if (currentIndex != -1 && currentIndex < items.length - 1) {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            items[currentIndex + 1].key,
            portraitIndex: vm.keyboardPortraitIndex,
          );
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.arrowLeft) {
        if (currentIndex > 0) {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            items[currentIndex - 1].key,
            portraitIndex: vm.keyboardPortraitIndex,
          );
        }
        return KeyEventResult.handled;
      }

      if (key == LogicalKeyboardKey.keyB) {
        if (vm.keyboardPhotoKey != null) {
          vm.setGroupBest(g.id, vm.keyboardPhotoKey!);
        }
        return KeyEventResult.handled;
      }
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final activeKey = isPortrait
          ? (portraitItems.isNotEmpty
                ? portraitItems[vm.keyboardPortraitIndex].key
                : null)
          : vm.keyboardPhotoKey;
      if (activeKey != null) {
        final targetKeys = vm.loupeSelection.isNotEmpty
            ? vm.loupeSelection.toList()
            : [activeKey];

        final items = targetKeys
            .map((k) => vm.entryByKey[k])
            .whereType<PhotoEntry>()
            .toList();
        if (items.isNotEmpty) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => LoupeScreen(
                items: items,
                scores: items.map((e) => e.sharpness).toList(),
                isBests: items.map((e) {
                  for (final g in vm.groups) {
                    if (g.items.any((item) => item.key == e.key)) {
                      return e.key == g.bestKey;
                    }
                  }
                  return false;
                }).toList(),
                initialSelectedForDelete: vm.selectedForDelete,
                onToggleDelete: (k, val) {
                  vm.toggleDeleteSelection(k);
                },
                onSetBest: (k) {
                  for (final g in vm.groups) {
                    if (g.items.any((item) => item.key == k)) {
                      vm.setGroupBest(g.id, k);
                      break;
                    }
                  }
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
          ? (portraitItems.isNotEmpty
                ? portraitItems[vm.keyboardPortraitIndex].key
                : null)
          : vm.keyboardPhotoKey;
      if (targetKey != null) {
        vm.toggleLoupeSelection(targetKey);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty
                ? portraitItems[vm.keyboardPortraitIndex].key
                : null)
          : vm.keyboardPhotoKey;
      if (targetKey != null) {
        vm.toggleDeleteSelection(targetKey);
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.delete) {
      _reviewAndDelete(vm);
      return KeyEventResult.handled;
    }

    int? getFolderIndex(LogicalKeyboardKey key) {
      if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
        return 0;
      }
      if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
        return 1;
      }
      if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
        return 2;
      }
      if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
        return 3;
      }
      if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
        return 4;
      }
      if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
        return 5;
      }
      if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
        return 6;
      }
      if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
        return 7;
      }
      if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
        return 8;
      }
      if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
        return 9;
      }
      return null;
    }

    final folderIndex = getFolderIndex(key);
    if (folderIndex != null && folderIndex < vm.customFolders.length) {
      final targetKey = isPortrait
          ? (portraitItems.isNotEmpty
                ? portraitItems[vm.keyboardPortraitIndex].key
                : null)
          : vm.keyboardPhotoKey;
      if (targetKey != null) {
        final targetFolder = vm.customFolders[folderIndex];
        if (vm.selectedSortFolders[targetKey] == targetFolder) {
          vm.setSortFolder(targetKey, null);
        } else {
          vm.setSortFolder(targetKey, targetFolder);
        }

        if (isPortrait) {
          if (vm.keyboardPortraitIndex < portraitItems.length - 1) {
            vm.setKeyboardFocus(
              vm.keyboardGroupIndex,
              vm.keyboardPhotoKey,
              portraitIndex: vm.keyboardPortraitIndex + 1,
            );
            _scrollToActiveGroup(vm, true);
          }
        } else {
          final g = vm.groups[vm.keyboardGroupIndex];
          final items = g.items;
          final currentIndex = items.indexWhere(
            (e) => e.key == vm.keyboardPhotoKey,
          );
          if (currentIndex != -1 && currentIndex < items.length - 1) {
            vm.setKeyboardFocus(
              vm.keyboardGroupIndex,
              items[currentIndex + 1].key,
              portraitIndex: vm.keyboardPortraitIndex,
            );
          }
        }
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<void> _runSortAndProcess(GroupsViewModel vm) async {
    final targets = vm.selectedSortFolders.entries
        .where((e) => !vm.processingKeys.contains(e.key))
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
              const Text(
                '• 移動：ファイルを新しいフォルダに移動します（元の場所からは削除されます）。',
                style: TextStyle(fontSize: 12),
              ),
              const Text(
                '• コピー：ファイルを新しいフォルダに複製します（元の場所にも残ります）。',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('移動する'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('コピーする'),
            ),
          ],
        );
      },
    );

    if (isCopy == null) return;

    final finalTargets = targets
        .where((e) => !vm.processingKeys.contains(e.key))
        .toList();

    if (finalTargets.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('選択された写真はすでに処理中です。')));
      }
      return;
    }

    final Map<String, String> currentSortMap = {
      for (final e in finalTargets) e.key: e.value,
    };

    vm.addProcessingKeys(currentSortMap.keys);
    vm.removeKeysFromSelection(currentSortMap.keys);

    final taskId = 'sort_${DateTime.now().millisecondsSinceEpoch}';
    final task = BackgroundTask(
      id: taskId,
      title: '写真を${isCopy ? "コピー" : "移動"}中',
      total: currentSortMap.length,
    );

    vm.addTask(task);

    vm.executeSortInBackground(
      task,
      currentSortMap,
      isCopy,
      (successCount) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$successCount 枚の写真を${isCopy ? "コピー" : "移動"}しました。'),
              backgroundColor: Colors.green,
            ),
          );
        }
      },
      (successCount, failCount) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) {
              return AlertDialog(
                title: const Text('仕分け完了（一部失敗）'),
                content: Text(
                  '$successCount 枚の処理は成功しましたが、$failCount 枚の処理に失敗しました。\n\n原因の例: ファイルのロック、容量不足、権限の喪失など。',
                ),
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
      },
      (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('処理中にシステムエラーが発生しました: $error'),
              backgroundColor: Colors.red,
            ),
          );
        }
      },
    );
  }

  Future<void> _addNewFolder(
    BuildContext context,
    GroupsViewModel vm,
    String key,
    bool isGrid,
  ) async {
    if (vm.customFolders.length >= 10) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('フォルダは最大10個までしか作成できません。')));
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
            decoration: const InputDecoration(hintText: 'フォルダ名を入力してください'),
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

      if (vm.customFolders.contains(newFolder)) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('同名のフォルダが既に存在します。')));
        }
        return;
      }

      vm.addCustomFolder(newFolder, key);
    }
  }

  Widget _buildSortFolderButtonForGrid(
    GroupsViewModel vm,
    String key,
    ThemeData theme,
  ) {
    final sortFolder = vm.selectedSortFolders[key];
    final hasFolder = sortFolder != null;
    return Material(
      color: Colors.transparent,
      child: PopupMenuButton<String?>(
        tooltip: 'フォルダに仕分ける',
        onSelected: (folder) {
          if (folder == '__NEW_FOLDER__') {
            _addNewFolder(context, vm, key, true);
          } else {
            vm.setSortFolder(key, folder);
          }
        },
        offset: const Offset(0, 30),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: hasFolder
                ? getFolderColor(sortFolder, vm.customFolders)
                : Colors.black.withValues(alpha: 0.5),
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
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
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
                  Icon(
                    Icons.create_new_folder,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
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
            ...vm.customFolders.map((folder) {
              return PopupMenuItem<String?>(
                value: folder,
                child: Row(
                  children: [
                    Icon(
                      Icons.folder,
                      size: 16,
                      color: getFolderColor(folder, vm.customFolders),
                    ),
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

  Widget _buildPortraitBody(
    BuildContext context,
    GroupsViewModel vm,
    List<PhotoEntry> portraitItems,
    bool isWide,
    double width,
    int crossAxisCount,
  ) {
    Widget buildItem(int index) {
      final e = portraitItems[index];
      final t = e.capturedAt;
      final timeStr = t == null
          ? ''
          : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
      final eyeText = e.portraitBothEyesDetected
          ? '目閉じなし'
          : (e.portraitEyesClosed ? '目閉じ' : '');

      final loupeSelected = vm.loupeSelection.contains(e.key);
      final selectedForDelete = vm.selectedForDelete.contains(e.key);
      final isKeyboardFocused = index == vm.keyboardPortraitIndex;
      final theme = Theme.of(context);
      final sortFolder = vm.selectedSortFolders[e.key];
      final hasFolder = sortFolder != null;

      return InkWell(
        onTap: () {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            vm.keyboardPhotoKey,
            portraitIndex: index,
          );
          vm.toggleDeleteSelection(e.key);
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
                              ? getFolderColor(sortFolder, vm.customFolders)
                              : (loupeSelected
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.5,
                                      )
                                    : theme.dividerColor.withValues(
                                        alpha: 0.12,
                                      )))),
              width: isKeyboardFocused
                  ? 2.5
                  : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(16),
                ),
                child: Stack(
                  children: [
                    Opacity(
                      opacity: selectedForDelete ? 0.45 : 1.0,
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(
                          selectedForDelete ? Colors.grey : Colors.transparent,
                          BlendMode.saturation,
                        ),
                        child: Image.file(
                          File(e.thumbnailPath!),
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
                            '${vm.loupeSelection.indexOf(e.key) + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Checkbox(
                        value: selectedForDelete,
                        onChanged: (v) {
                          vm.setKeyboardFocus(
                            vm.keyboardGroupIndex,
                            vm.keyboardPhotoKey,
                            portraitIndex: index,
                          );
                          vm.toggleDeleteSelection(e.key);
                        },
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        side: const BorderSide(color: Colors.white, width: 1.5),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            vm.setKeyboardFocus(
                              vm.keyboardGroupIndex,
                              vm.keyboardPhotoKey,
                              portraitIndex: index,
                            );
                            vm.toggleLoupeSelection(e.key);
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
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: _buildSortFolderButtonForGrid(vm, e.key, theme),
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
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
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

      final loupeSelected = vm.loupeSelection.contains(e.key);
      final selectedForDelete = vm.selectedForDelete.contains(e.key);
      final isKeyboardFocused = index == vm.keyboardPortraitIndex;
      final theme = Theme.of(context);
      final sortFolder = vm.selectedSortFolders[e.key];
      final hasFolder = sortFolder != null;

      return InkWell(
        onTap: () {
          vm.setKeyboardFocus(
            vm.keyboardGroupIndex,
            vm.keyboardPhotoKey,
            portraitIndex: index,
          );
          vm.toggleDeleteSelection(e.key);
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
                              ? getFolderColor(sortFolder, vm.customFolders)
                              : (loupeSelected
                                    ? theme.colorScheme.primary.withValues(
                                        alpha: 0.5,
                                      )
                                    : theme.dividerColor.withValues(
                                        alpha: 0.12,
                                      )))),
              width: isKeyboardFocused
                  ? 2.5
                  : (selectedForDelete || hasFolder || loupeSelected ? 2 : 1),
            ),
            boxShadow: isKeyboardFocused
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(15),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(
                        opacity: selectedForDelete ? 0.45 : 1.0,
                        child: ColorFiltered(
                          colorFilter: ColorFilter.mode(
                            selectedForDelete
                                ? Colors.grey
                                : Colors.transparent,
                            BlendMode.saturation,
                          ),
                          child: Image.file(
                            File(e.thumbnailPath!),
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
                              '${vm.loupeSelection.indexOf(e.key) + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Checkbox(
                          value: selectedForDelete,
                          onChanged: (v) {
                            vm.setKeyboardFocus(
                              vm.keyboardGroupIndex,
                              vm.keyboardPhotoKey,
                              portraitIndex: index,
                            );
                            vm.toggleDeleteSelection(e.key);
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          side: const BorderSide(
                            color: Colors.white,
                            width: 1.5,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              vm.setKeyboardFocus(
                                vm.keyboardGroupIndex,
                                vm.keyboardPhotoKey,
                                portraitIndex: index,
                              );
                              vm.toggleLoupeSelection(e.key);
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
                                loupeSelected
                                    ? Icons.zoom_in_map
                                    : Icons.zoom_in,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: _buildSortFolderButtonForGrid(vm, e.key, theme),
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
      final itemWidth =
          (width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
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

  Widget _buildGroupBody(
    BuildContext context,
    GroupsViewModel vm,
    bool isWide,
    double width,
    int crossAxisCount,
  ) {
    Widget buildItem(int index) {
      final g = vm.groups[index];
      final isKeyboardGroupFocused = index == vm.keyboardGroupIndex;

      return ExpandableGroupCard(
        group: g,
        selectedForDelete: vm.selectedForDelete,
        onToggleDelete: (key, v) {
          vm.toggleDeleteSelection(key);
        },
        loupeSelection: vm.loupeSelection,
        onToggleLoupe: (key) {
          vm.toggleLoupeSelection(key);
        },
        onSelectBestOnly: () {
          final toAdd = g.items
              .where((item) => item.key != g.bestKey)
              .map((e) => e.key)
              .toList();
          for (final key in toAdd) {
            if (!vm.selectedForDelete.contains(key)) {
              vm.toggleDeleteSelection(key);
            }
          }
          if (vm.selectedForDelete.contains(g.bestKey)) {
            vm.toggleDeleteSelection(g.bestKey);
          }
        },
        isKeyboardGroupFocused: isKeyboardGroupFocused,
        keyboardPhotoKey: isKeyboardGroupFocused ? vm.keyboardPhotoKey : null,
        onPhotoTileFocused: (key) {
          vm.setKeyboardFocus(
            index,
            key,
            portraitIndex: vm.keyboardPortraitIndex,
          );
        },
        selectedSortFolders: vm.selectedSortFolders,
        customFolders: vm.customFolders,
        processingKeys: vm.processingKeys,
        onSortFolderChanged: (key, folder) {
          if (folder == '__NEW_FOLDER__') {
            _addNewFolder(context, vm, key, false);
          } else {
            vm.setSortFolder(key, folder);
          }
        },
      );
    }

    if (isWide) {
      final itemWidth =
          (width - 32 - (crossAxisCount - 1) * 16) / crossAxisCount;
      return SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (int i = 0; i < vm.groups.length; i++)
              SizedBox(width: itemWidth, child: buildItem(i)),
          ],
        ),
      );
    } else {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: vm.groups.length,
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
    final vm = ref.watch(groupsViewModelProvider(widget.groups));

    return ListenableBuilder(
      listenable: vm,
      builder: (context, child) {
        final colorScheme = Theme.of(context).colorScheme;
        final size = MediaQuery.of(context).size;
        final isWide = size.width >= 800;
        final isMobile = size.width < 600;
        final crossAxisCount = size.width >= 800 ? 2 : 1;

        final isPortrait = widget.detectionMode == DetectionMode.portrait;
        final portraitItems = isPortrait
            ? vm.entryByKey.values.toList()
            : const <PhotoEntry>[];
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

        final bool canSort = vm.selectedSortFolders.keys.any(
          (k) => !vm.processingKeys.contains(k),
        );
        final bool canDelete = vm.selectedForDelete.any(
          (k) => !vm.processingKeys.contains(k),
        );
        final bool canExport = vm.backgroundTasks.isEmpty;

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (node, event) => _handleKeyEvent(event, vm),
          child: Scaffold(
            backgroundColor: colorScheme.surfaceContainer.withValues(
              alpha: 0.3,
            ),
            appBar: AppBar(
              title: isMobile
                  ? const Text(
                      '整理・比較',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('整理・比較'),
                        Text(
                          isPortrait
                              ? '写真: ${portraitItems.length} / 顔あり: ${portraitItems.where((e) => e.hasPortraitFace).length} / 削除候補: ${vm.selectedForDelete.length}'
                              : 'グループ: ${vm.groups.length} / 削除候補: ${vm.selectedForDelete.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
              actions: [
                if (!isPortrait)
                  isMobile
                      ? IconButton(
                          tooltip: 'Bestのみ保存',
                          icon: const Icon(Icons.folder_shared),
                          onPressed: canExport
                              ? () => _exportBestShots(vm)
                              : null,
                          color: colorScheme.primary,
                        )
                      : Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilledButton.icon(
                            onPressed: canExport
                                ? () => _exportBestShots(vm)
                                : null,
                            icon: const Icon(Icons.folder_shared, size: 20),
                            label: const Text('Bestのみ保存'),
                            style: FilledButton.styleFrom(
                              backgroundColor: colorScheme.primaryContainer,
                              foregroundColor: colorScheme.onPrimaryContainer,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                            ),
                          ),
                        ),
                isMobile
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Badge(
                          label: Text('${vm.selectedSortFolders.length}'),
                          isLabelVisible: vm.selectedSortFolders.isNotEmpty,
                          child: IconButton(
                            tooltip: '仕分け実行',
                            icon: const Icon(Icons.folder_copy),
                            onPressed: canSort
                                ? () => _runSortAndProcess(vm)
                                : null,
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Badge(
                          label: Text('${vm.selectedSortFolders.length}'),
                          isLabelVisible: vm.selectedSortFolders.isNotEmpty,
                          child: FilledButton.icon(
                            onPressed: canSort
                                ? () => _runSortAndProcess(vm)
                                : null,
                            icon: const Icon(Icons.folder_copy, size: 20),
                            label: const Text('仕分け実行'),
                            style: FilledButton.styleFrom(
                              backgroundColor: colorScheme.primaryContainer,
                              foregroundColor: colorScheme.onPrimaryContainer,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                if (vm.loupeSelection.isNotEmpty)
                  IconButton(
                    tooltip: 'ルーペ選択を解除',
                    onPressed: vm.clearLoupeSelection,
                    icon: const Icon(Icons.deselect),
                  ),
                isMobile
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Badge(
                          label: Text('${vm.loupeSelection.length}'),
                          isLabelVisible: vm.loupeSelection.isNotEmpty,
                          child: IconButton(
                            tooltip: 'ルーペ比較',
                            icon: const Icon(Icons.zoom_in),
                            onPressed: vm.loupeSelection.isNotEmpty
                                ? () {
                                    final items = vm.loupeSelection
                                        .map((k) => vm.entryByKey[k])
                                        .whereType<PhotoEntry>()
                                        .toList();
                                    if (items.isEmpty) return;
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) => LoupeScreen(
                                          items: items,
                                          scores: vm.loupeSelection
                                              .map((k) => vm.entryByKey[k])
                                              .whereType<PhotoEntry>()
                                              .map((e) => e.sharpness)
                                              .toList(),
                                          isBests: vm.loupeSelection
                                              .map((k) => vm.entryByKey[k])
                                              .whereType<PhotoEntry>()
                                              .map((e) {
                                                for (final g in vm.groups) {
                                                  if (g.items.any(
                                                    (item) => item.key == e.key,
                                                  )) {
                                                    return e.key == g.bestKey;
                                                  }
                                                }
                                                return false;
                                              })
                                              .toList(),
                                          initialSelectedForDelete:
                                              vm.selectedForDelete,
                                          onToggleDelete: (key, val) {
                                            vm.toggleDeleteSelection(key);
                                          },
                                          onSetBest: (key) {
                                            for (final g in vm.groups) {
                                              if (g.items.any(
                                                (item) => item.key == key,
                                              )) {
                                                vm.setGroupBest(g.id, key);
                                                break;
                                              }
                                            }
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
                          onPressed: vm.loupeSelection.isNotEmpty
                              ? () {
                                  final items = vm.loupeSelection
                                      .map((k) => vm.entryByKey[k])
                                      .whereType<PhotoEntry>()
                                      .toList();
                                  if (items.isEmpty) return;
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => LoupeScreen(
                                        items: items,
                                        scores: vm.loupeSelection
                                            .map((k) => vm.entryByKey[k])
                                            .whereType<PhotoEntry>()
                                            .map((e) => e.sharpness)
                                            .toList(),
                                        isBests: vm.loupeSelection
                                            .map((k) => vm.entryByKey[k])
                                            .whereType<PhotoEntry>()
                                            .map((e) {
                                              for (final g in vm.groups) {
                                                if (g.items.any(
                                                  (item) => item.key == e.key,
                                                )) {
                                                  return e.key == g.bestKey;
                                                }
                                              }
                                              return false;
                                            })
                                            .toList(),
                                        initialSelectedForDelete:
                                            vm.selectedForDelete,
                                        onToggleDelete: (key, val) {
                                          vm.toggleDeleteSelection(key);
                                        },
                                        onSetBest: (key) {
                                          for (final g in vm.groups) {
                                            if (g.items.any(
                                              (item) => item.key == key,
                                            )) {
                                              vm.setGroupBest(g.id, key);
                                              break;
                                            }
                                          }
                                        },
                                      ),
                                    ),
                                  );
                                }
                              : null,
                          icon: const Icon(Icons.zoom_in, size: 20),
                          label: Text('ルーペ (${vm.loupeSelection.length}/4)'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                        ),
                      ),
                isMobile
                    ? Padding(
                        padding: const EdgeInsets.only(left: 8, right: 12),
                        child: Badge(
                          label: Text('${vm.selectedForDelete.length}'),
                          isLabelVisible: vm.selectedForDelete.isNotEmpty,
                          backgroundColor: colorScheme.error,
                          textColor: colorScheme.onError,
                          child: IconButton(
                            tooltip: 'ゴミ箱へ',
                            icon: Icon(
                              Icons.delete_outline,
                              color: vm.selectedForDelete.isNotEmpty
                                  ? colorScheme.error
                                  : null,
                            ),
                            onPressed: canDelete
                                ? () => _reviewAndDelete(vm)
                                : null,
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: FilledButton.icon(
                          onPressed: canDelete
                              ? () => _reviewAndDelete(vm)
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
                      ? _buildPortraitBody(
                          context,
                          vm,
                          portraitItems,
                          isWide,
                          size.width,
                          crossAxisCount,
                        )
                      : _buildGroupBody(
                          context,
                          vm,
                          isWide,
                          size.width,
                          crossAxisCount,
                        ),
                ),
                if (vm.backgroundTasks.isNotEmpty)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: BottomProgressOverlay(
                      tasks: vm.backgroundTasks,
                      colorScheme: colorScheme,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
