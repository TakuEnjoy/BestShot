import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../models/photo_entry.dart';
import '../../models/photo_group.dart';
import '../../services/deleting/delete_service.dart';
import '../../services/sorting/sort_service.dart';

class BackgroundTask {
  BackgroundTask({
    required this.id,
    required this.title,
    required this.total,
    this.progress = 0.0,
    this.statusText = '準備中...',
    this.isError = false,
  });

  final String id;
  final String title;
  final int total;
  double progress;
  String statusText;
  final bool isError;
}

class GroupsViewModel extends ChangeNotifier {
  GroupsViewModel(List<PhotoGroup> initialGroups) {
    _groups = initialGroups;
    _entryByKey = {
      for (final g in _groups)
        for (final e in g.items) e.key: e,
    };
    _selectedForDelete = {for (final g in _groups) ...g.deleteCandidateKeys};
    if (_groups.isNotEmpty) {
      _keyboardPhotoKey = _groups.first.bestKey;
    }
  }

  late List<PhotoGroup> _groups;
  List<PhotoGroup> get groups => _groups;

  late Map<String, PhotoEntry> _entryByKey;
  Map<String, PhotoEntry> get entryByKey => _entryByKey;

  late Set<String> _selectedForDelete;
  Set<String> get selectedForDelete => _selectedForDelete;

  final List<String> _loupeSelection = [];
  List<String> get loupeSelection => _loupeSelection;

  final Map<String, String> _selectedSortFolders = {};
  Map<String, String> get selectedSortFolders => _selectedSortFolders;

  final List<String> _customFolders = [];
  List<String> get customFolders => _customFolders;

  final Set<String> _processingKeys = {};
  Set<String> get processingKeys => _processingKeys;

  final List<BackgroundTask> _backgroundTasks = [];
  List<BackgroundTask> get backgroundTasks => _backgroundTasks;

  int _keyboardGroupIndex = 0;
  int get keyboardGroupIndex => _keyboardGroupIndex;

  String? _keyboardPhotoKey;
  String? get keyboardPhotoKey => _keyboardPhotoKey;

  int _keyboardPortraitIndex = 0;
  int get keyboardPortraitIndex => _keyboardPortraitIndex;

  void toggleDeleteSelection(String key) {
    if (_selectedForDelete.contains(key)) {
      _selectedForDelete.remove(key);
    } else {
      _selectedForDelete.add(key);
    }
    notifyListeners();
  }

  void setGroupBest(String groupId, String photoKey) {
    for (final g in _groups) {
      if (g.id == groupId) {
        g.bestKey = photoKey;
        break;
      }
    }
    notifyListeners();
  }

  void toggleLoupeSelection(String key) {
    if (_loupeSelection.contains(key)) {
      _loupeSelection.remove(key);
    } else {
      if (_loupeSelection.length >= 4) {
        _loupeSelection.removeAt(0);
      }
      _loupeSelection.add(key);
    }
    notifyListeners();
  }

  void clearLoupeSelection() {
    _loupeSelection.clear();
    notifyListeners();
  }

  void setSortFolder(String groupKey, String? folderName) {
    if (folderName == null) {
      _selectedSortFolders.remove(groupKey);
    } else {
      _selectedSortFolders[groupKey] = folderName;
    }
    notifyListeners();
  }

  void addCustomFolder(String folderName, String? groupKey) {
    if (!_customFolders.contains(folderName)) {
      _customFolders.add(folderName);
      if (groupKey != null) {
        _selectedSortFolders[groupKey] = folderName;
      }
      notifyListeners();
    }
  }

  void setKeyboardFocus(
    int groupIndex,
    String? photoKey, {
    int portraitIndex = 0,
  }) {
    _keyboardGroupIndex = groupIndex;
    _keyboardPhotoKey = photoKey;
    _keyboardPortraitIndex = portraitIndex;
    notifyListeners();
  }

  void addProcessingKeys(Iterable<String> keys) {
    _processingKeys.addAll(keys);
    notifyListeners();
  }

  void removeProcessingKeys(Iterable<String> keys) {
    _processingKeys.removeAll(keys);
    notifyListeners();
  }

  void removeKeysFromSelection(Iterable<String> keys) {
    _selectedForDelete.removeAll(keys);
    _selectedSortFolders.removeWhere((key, _) => keys.contains(key));
    notifyListeners();
  }

  void removeEntries(Iterable<PhotoEntry> entries) {
    for (final entry in entries) {
      _entryByKey.remove(entry.key);
      for (final g in _groups) {
        g.items.removeWhere((item) => item.key == entry.key);
      }
    }
    _groups.removeWhere((g) => g.items.isEmpty);
    notifyListeners();
  }

  void addTask(BackgroundTask task) {
    _backgroundTasks.add(task);
    notifyListeners();
  }

  void updateTaskProgress(String id, double progress, String statusText) {
    final idx = _backgroundTasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _backgroundTasks[idx].progress = progress;
      _backgroundTasks[idx].statusText = statusText;
      notifyListeners();
    }
  }

  void removeTask(String id) {
    _backgroundTasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  Future<int?> exportBestShots(String selectedDirectory) async {
    final sourcePaths = <String>[];
    for (final group in _groups) {
      if (group.items.isEmpty) continue;
      final bestItem = group.items.firstWhere(
        (item) => item.key == group.bestKey,
        orElse: () => group.items.first,
      );
      final sourcePath = bestItem.filePath;
      if (sourcePath != null) {
        sourcePaths.add(sourcePath);
      }
    }

    final count = await Isolate.run(() async {
      int copiedCount = 0;
      for (final sourcePath in sourcePaths) {
        final file = File(sourcePath);
        if (await file.exists()) {
          final filename = p.basename(sourcePath);
          final destPath = p.join(selectedDirectory, filename);

          var finalDestPath = destPath;
          var suffix = 1;
          final nameWithoutExt = p.basenameWithoutExtension(sourcePath);
          final ext = p.extension(sourcePath);
          while (await File(finalDestPath).exists()) {
            finalDestPath = p.join(
              selectedDirectory,
              '${nameWithoutExt}_$suffix$ext',
            );
            suffix++;
          }

          await file.copy(finalDestPath);
          copiedCount++;
        }
      }
      return copiedCount;
    });

    return count;
  }

  Future<void> executeDeleteInBackground(
    BackgroundTask task,
    List<String> targets,
    Function(String) onError,
    Function() onSuccess,
  ) async {
    final entries = targets
        .map((k) => _entryByKey[k])
        .whereType<PhotoEntry>()
        .toList();

    try {
      updateTaskProgress(task.id, 0.5, 'ゴミ箱へ移動中...');
      await DeleteService.moveToTrash(entries);

      removeProcessingKeys(targets);
      removeEntries(entries);
      onSuccess();
    } catch (e) {
      removeProcessingKeys(targets);
      onError(e.toString());
    } finally {
      removeTask(task.id);
    }
  }

  Future<void> executeSortInBackground(
    BackgroundTask task,
    Map<String, String> currentSortMap,
    bool isCopy,
    Function(int) onSuccess,
    Function(int, int) onPartialSuccess,
    Function(String) onError,
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
          updateTaskProgress(
            task.id,
            total <= 0 ? 0.0 : done / total,
            '処理中... ($done / $total)',
          );
        },
      );

      final entryMapByPath = {
        for (final e in _entryByKey.values) e.filePath: e,
      };
      final failedKeys = result.failedFiles
          .map((path) => entryMapByPath[path]?.key)
          .whereType<String>()
          .toSet();

      final successKeys = currentSortMap.keys
          .where((key) => !failedKeys.contains(key))
          .toSet();

      removeProcessingKeys(currentSortMap.keys);

      if (!isCopy && successKeys.isNotEmpty) {
        final successEntries = successKeys
            .map((k) => _entryByKey[k])
            .whereType<PhotoEntry>()
            .toList();
        removeEntries(successEntries);
      }

      if (result.failedFiles.isEmpty) {
        onSuccess(result.successCount);
      } else {
        onPartialSuccess(result.successCount, result.failedFiles.length);
      }
    } catch (e) {
      removeProcessingKeys(currentSortMap.keys);
      onError(e.toString());
    } finally {
      removeTask(task.id);
    }
  }
}
