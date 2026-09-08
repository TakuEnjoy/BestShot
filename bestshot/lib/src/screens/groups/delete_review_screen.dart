part of '../groups_screen.dart';

class DeleteReviewScreen extends StatefulWidget {
  const DeleteReviewScreen({
    super.key,
    required this.items,
    required this.onRemoveFromDelete,
    this.groups = const [],
  });

  final List<PhotoEntry> items;
  final Function(String key) onRemoveFromDelete;
  final List<PhotoGroup> groups;

  @override
  State<DeleteReviewScreen> createState() => _DeleteReviewScreenState();
}

class _DeleteReviewScreenState extends State<DeleteReviewScreen> with SingleTickerProviderStateMixin {
  final List<String> _loupeSelection = [];
  late List<PhotoEntry> _currentItems;

  late AnimationController _holdController;
  bool _isHolding = false;

  @override
  void initState() {
    super.initState();
    _currentItems = List.from(widget.items);
    _holdController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _holdController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _onHoldCompleted();
      }
    });
  }

  @override
  void dispose() {
    _holdController.dispose();
    super.dispose();
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

  double _calculateTotalMb() {
    double totalBytes = 0;
    for (final item in _currentItems) {
      if (item.filePath != null) {
        try {
          final f = File(item.filePath!);
          if (f.existsSync()) {
            totalBytes += f.lengthSync();
            continue;
          }
        } catch (_) {}
      }
      totalBytes += item.displayBytes.length * 8;
    }
    return totalBytes / (1024 * 1024);
  }

  Map<String, int> _getGroupBreakdown() {
    final counts = <String, int>{};
    for (final item in _currentItems) {
      String groupId = 'その他';
      for (final g in widget.groups) {
        if (g.items.any((e) => e.key == item.key)) {
          groupId = g.id;
          break;
        }
      }
      counts[groupId] = (counts[groupId] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> _onHoldCompleted() async {
    setState(() {
      _isHolding = false;
    });
    _holdController.reset();

    HapticFeedback.heavyImpact();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: BestShotTheme.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: const BorderSide(color: BestShotTheme.dividerColor),
          ),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: BestShotTheme.accentRed, size: 22),
              SizedBox(width: 8),
              Text('本当に削除しますか？'),
            ],
          ),
          content: Text(
            '選択された ${_currentItems.length}枚 の画像を完全に削除します。\n削除実行後は元に戻すことはできません。',
            style: const TextStyle(fontSize: 13, color: BestShotTheme.textPrimary),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: BestShotTheme.accentRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('削除を実行'),
            ),
          ],
        );
      },
    );

    if (confirm == true && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMb = _calculateTotalMb();
    final breakdown = _getGroupBreakdown();

    return Scaffold(
      backgroundColor: BestShotTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: BestShotTheme.backgroundPrimary,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: BestShotTheme.textPrimary),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: const Text(
          '⚠️ 削除前最終確認',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: BestShotTheme.textPrimary),
        ),
        actions: [
          if (_loupeSelection.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () {
                  final items = _loupeSelection
                      .map((key) => _currentItems.firstWhere((e) => e.key == key))
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
                },
                icon: const Icon(Icons.zoom_in, size: 16, color: BestShotTheme.accentBlue),
                label: Text('ルーペ (${_loupeSelection.length}/4)'),
              ),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // サブタイトル
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: BestShotTheme.surfaceColor,
            child: Text(
              '選択された ${_currentItems.length}枚 の画像を完全に削除します',
              style: const TextStyle(fontSize: 13, color: BestShotTheme.textSecondary),
            ),
          ),

          // 4列グリッド (Section 2.4)
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
                childAspectRatio: 1.0,
              ),
              itemCount: _currentItems.length,
              itemBuilder: (context, i) {
                final item = _currentItems[i];
                final isSelectedForLoupe = _loupeSelection.contains(item.key);

                return Container(
                  decoration: BoxDecoration(
                    color: BestShotTheme.surfaceColor,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isSelectedForLoupe ? BestShotTheme.accentBlue : BestShotTheme.accentRed,
                      width: 2.0,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 画像
                      Opacity(
                        opacity: 0.65,
                        child: Image.memory(
                          item.displayBytes,
                          fit: BoxFit.cover,
                          cacheWidth: 300,
                        ),
                      ),

                      // 赤枠 🗑️ バッジ (右上)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: BestShotTheme.accentRed,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: const Icon(Icons.delete_outline, size: 12, color: Colors.white),
                        ),
                      ),

                      // 削除リストから除外ボタン (左上)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              widget.onRemoveFromDelete(item.key);
                              setState(() {
                                _currentItems.remove(item);
                                _loupeSelection.remove(item.key);
                              });
                              if (_currentItems.isEmpty) {
                                Navigator.of(context).pop(false);
                              }
                            },
                            borderRadius: BorderRadius.circular(2),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: const Icon(Icons.close, size: 12, color: Colors.white),
                            ),
                          ),
                        ),
                      ),

                      // ルーペ比較トグル (右下)
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _toggleLoupe(item.key),
                            borderRadius: BorderRadius.circular(2),
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: isSelectedForLoupe
                                    ? BestShotTheme.accentBlue
                                    : Colors.black.withValues(alpha: 0.65),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: Icon(
                                isSelectedForLoupe ? Icons.zoom_in_map : Icons.zoom_in,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          // 元グループ内訳 ＆ 総容量表示カード (Section 2.4)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BestShotTheme.surfaceColor,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: BestShotTheme.dividerColor, width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in breakdown.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.folder_outlined, size: 14, color: BestShotTheme.textSecondary),
                        const SizedBox(width: 6),
                        Text(
                          'グループ #${entry.key} から ${entry.value}枚',
                          style: const TextStyle(fontSize: 12, color: BestShotTheme.textPrimary),
                        ),
                      ],
                    ),
                  ),
                const Divider(color: BestShotTheme.dividerColor, height: 16),
                Row(
                  children: [
                    Text(
                      '合計: ${_currentItems.length}枚',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: BestShotTheme.textPrimary),
                    ),
                    const SizedBox(width: 12),
                    Text('│', style: TextStyle(color: BestShotTheme.dividerColor)),
                    const SizedBox(width: 12),
                    Text(
                      '総容量: ${totalMb.toStringAsFixed(1)}MB',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: BestShotTheme.accentGold),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 下部操作バー: [🔙 戻る]  [🗑️ 完全削除 (長押しで実行)]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: BestShotTheme.surfaceColor,
              border: Border(top: BorderSide(color: BestShotTheme.dividerColor, width: 1)),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('戻る'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    onTapDown: (_) {
                      setState(() => _isHolding = true);
                      _holdController.forward();
                    },
                    onTapUp: (_) {
                      if (_holdController.status != AnimationStatus.completed) {
                        setState(() => _isHolding = false);
                        _holdController.reset();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('誤タップ防止のため、削除ボタンを長押ししてください'),
                            duration: Duration(milliseconds: 1500),
                          ),
                        );
                      }
                    },
                    onTapCancel: () {
                      setState(() => _isHolding = false);
                      _holdController.reset();
                    },
                    child: AnimatedBuilder(
                      animation: _holdController,
                      builder: (context, child) {
                        return Container(
                          height: 44,
                          decoration: BoxDecoration(
                            color: BestShotTheme.accentRed,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            children: [
                              // 長押しホールド進行インジケーター
                              Positioned(
                                left: 0,
                                top: 0,
                                bottom: 0,
                                width: MediaQuery.of(context).size.width * 0.6 * _holdController.value,
                                child: Container(
                                  color: Colors.white.withValues(alpha: 0.35),
                                ),
                              ),
                              Center(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.delete_forever, size: 18, color: Colors.white),
                                    const SizedBox(width: 8),
                                    Text(
                                      _isHolding
                                          ? 'そのまま保持してください...'
                                          : '完全削除 (長押しで実行)',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
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
