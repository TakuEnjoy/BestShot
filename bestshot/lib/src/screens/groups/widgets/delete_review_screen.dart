import 'dart:io';

import 'package:flutter/material.dart';

import '../../../models/photo_entry.dart';
import '../../loupe_screen.dart';

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
                        child: Image.file(
                          File(item.thumbnailPath!),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    if (isSelectedForLoupe)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 3,
                            ),
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.1,
                            ),
                          ),
                        ),
                      ),
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
                  color: Colors.black.withValues(alpha: 0.1),
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
