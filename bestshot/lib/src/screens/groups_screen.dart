import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/photo_entry.dart';
import '../models/photo_group.dart';
import '../services/analysis/analysis_types.dart';
import '../services/deleting/delete_service.dart';
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
    if (_selectedForDelete.isEmpty || _deleting) return;

    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DeleteReviewScreen(
          items: _selectedForDelete.map((k) => _entryByKey[k]!).toList(),
          onRemoveFromDelete: (key) {
            setState(() => _selectedForDelete.remove(key));
          },
        ),
      ),
    );

    if (result == true) {
      // User confirmed delete in review screen
      setState(() => _deleting = true);
      try {
        final entries = _selectedForDelete
            .map((k) => _entryByKey[k])
            .whereType<PhotoEntry>()
            .toList();
        await DeleteService.moveToTrash(entries);
        if (!mounted) return;
        setState(() => _selectedForDelete.clear());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('ゴミ箱へ移動しました')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('失敗: $e')));
      } finally {
        if (mounted) setState(() => _deleting = false);
      }
    }
  }

  void _scrollToActiveGroup(bool isPortrait) {
    if (!_scrollController.hasClients) return;
    if (isPortrait) {
      final targetOffset = _keyboardPortraitIndex * 130.0;
      final currentOffset = _scrollController.offset;
      final viewHeight = MediaQuery.of(context).size.height;
      if (targetOffset < currentOffset || targetOffset > currentOffset + viewHeight - 200) {
        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeInOut,
        );
      }
    } else {
      final targetOffset = _keyboardGroupIndex * 220.0;
      final currentOffset = _scrollController.offset;
      final viewHeight = MediaQuery.of(context).size.height;
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

      if (key == LogicalKeyboardKey.keyB ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (_keyboardPhotoKey != null) {
          setState(() {
            g.bestKey = _keyboardPhotoKey!;
          });
        }
        return KeyEventResult.handled;
      }
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

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

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

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        backgroundColor: colorScheme.surfaceContainer.withOpacity(0.3),
        appBar: AppBar(
          title: Column(
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
            if (!isPortrait)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _deleting ? null : _exportBestShots,
                  icon: const Icon(Icons.folder_shared, size: 20),
                  label: const Text('Bestのみ保存'),
                  style: FilledButton.styleFrom(
                    backgroundColor: colorScheme.primaryContainer,
                    foregroundColor: colorScheme.onPrimaryContainer,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
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
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: (_selectedForDelete.isEmpty || _deleting)
                    ? null
                    : _reviewAndDelete,
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
        body: isPortrait
            ? ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: portraitItems.length,
                itemBuilder: (context, index) {
                  final e = portraitItems[index];
                  final t = e.capturedAt;
                  final timeStr = t == null
                      ? ''
                      : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

                  final eyeText = e.portraitBothEyesDetected
                      ? '目閉じなし'
                      : (e.portraitEyesClosed ? '目閉じ' : '');

                  final loupeSelected = _loupeSelection.contains(e.key);
                  final isKeyboardFocused = index == _keyboardPortraitIndex;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
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
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isKeyboardFocused
                                ? Theme.of(context).colorScheme.primary
                                : (loupeSelected
                                    ? Theme.of(context).colorScheme.primary.withOpacity(0.5)
                                    : Theme.of(context).dividerColor.withOpacity(0.12)),
                            width: isKeyboardFocused ? 2.5 : (loupeSelected ? 2 : 1),
                          ),
                          boxShadow: isKeyboardFocused
                              ? [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary.withOpacity(0.25),
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
                                  Image.memory(
                                    e.displayBytes,
                                    width: 120,
                                    height: 120,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                  if (loupeSelected)
                                    Positioned(
                                      top: 8,
                                      left: 8,
                                      child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.primary,
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
                    ),
                  );
                },
              )
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                itemCount: widget.groups.length,
                itemBuilder: (context, index) {
                  final g = widget.groups[index];
                  final isKeyboardGroupFocused = index == _keyboardGroupIndex;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ExpandableGroupCard(
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
                    ),
                  );
                },
              ),
      ),
    );
  }
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
                if (group.isAllBlur) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning_amber_rounded, size: 14, color: theme.colorScheme.error),
                        const SizedBox(width: 4),
                        Text(
                          '全て手ブレ/ピンボケの可能性あり',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
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

class _PhotoTile extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return InkWell(
      onTap: () => onChanged(!selectedForDelete),
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          // Image and its clipping
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Opacity(
                opacity: selectedForDelete ? 0.45 : 1.0,
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(
                    selectedForDelete ? Colors.grey : Colors.transparent,
                    BlendMode.saturation,
                  ),
                  child: Image.memory(
                    bytes,
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
                  border: isKeyboardFocused
                      ? Border.all(color: colorScheme.primary, width: 3)
                      : (selectedForDelete
                          ? Border.all(color: colorScheme.error, width: 3)
                          : (isBest
                              ? Border.all(color: const Color(0xFF22C55E), width: 2.5)
                              : Border.all(
                                  color: Colors.white.withOpacity(0.1),
                                  width: 1,
                                ))),
                  boxShadow: isKeyboardFocused
                      ? [
                          BoxShadow(
                            color: colorScheme.primary.withOpacity(0.5),
                            blurRadius: 10,
                            spreadRadius: 1.5,
                          )
                        ]
                      : (isBest
                          ? [
                              BoxShadow(
                                color: const Color(0xFF22C55E).withOpacity(0.4),
                                blurRadius: 8,
                                spreadRadius: 1,
                              )
                            ]
                          : null),
                  color: selectedForDelete
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
                if (isBest)
                  const _Badge(label: 'Best', color: Color(0xFF22C55E)),
                if (!isBest)
                  _Badge(
                    label: sharpness.toStringAsFixed(0),
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
              value: selectedForDelete,
              onChanged: (v) => onChanged(v ?? false),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              side: const BorderSide(color: Colors.white, width: 1.5),
            ),
          ),

          // EXIF Overlay (Bottom)
          if (exifText.isNotEmpty)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
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
                      exifText,
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
                onTap: onToggleLoupe,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: loupeSelected
                        ? colorScheme.primary
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
        ],
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
