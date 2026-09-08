part of '../groups_screen.dart';

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
                        borderRadius: BorderRadius.circular(16),
                        child: Image.memory(
                          item.displayBytes,
                          fit: BoxFit.cover,
                          cacheWidth: 400,
                        ),
                      ),
                    ),
                    // Selection overlay for loupe
                    if (isSelectedForLoupe)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: theme.colorScheme.primary,
                              width: 3,
                            ),
                            color: theme.colorScheme.primary.withValues(alpha: 0.12),
                          ),
                        ),
                      ),
                    // Info overlay (Pill)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          item.sharpness.toStringAsFixed(0),
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // Actions
                    Positioned(
                      right: 6,
                      top: 6,
                      child: IconButton.filled(
                        iconSize: 18,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          shape: const CircleBorder(),
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
                      right: 6,
                      bottom: 6,
                      child: IconButton.filled(
                        iconSize: 18,
                        style: IconButton.styleFrom(
                          backgroundColor: isSelectedForLoupe
                              ? theme.colorScheme.primary
                              : Colors.black54,
                          shape: const CircleBorder(),
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
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2)),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 16,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
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
                        backgroundColor: theme.colorScheme.errorContainer,
                        foregroundColor: theme.colorScheme.onErrorContainer,
                      ),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: Text('${_currentItems.length}件をゴミ箱へ移動'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
