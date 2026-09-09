import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/global_background.dart';
import '../widgets/glass_container.dart';

import '../models/photo_entry.dart';
import '../services/analysis/focus_mask_service.dart';

enum LoupeHudMode {
  compact('コンパクト', Icons.subtitles_outlined),
  detailed('詳細', Icons.info_outline),
  clean('クリーン', Icons.visibility_off_outlined);

  const LoupeHudMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

class LoupeScreen extends StatefulWidget {
  const LoupeScreen({
    super.key,
    required this.items,
    required this.scores,
    required this.isBests,
    this.initialSelectedForDelete,
    this.onToggleDelete,
    this.onSetBest,
  });

  final List<PhotoEntry> items;
  final List<double> scores;
  final List<bool> isBests;
  final Set<String>? initialSelectedForDelete;
  final void Function(String key, bool val)? onToggleDelete;
  final void Function(String key)? onSetBest;

  // Cache focus mask bytes for the duration of the app session with LRU limit of 50
  static final FocusMaskCache _sessionMaskCache = FocusMaskCache(
    maxEntries: 50,
  );

  @override
  State<LoupeScreen> createState() => _LoupeScreenState();
}

class _LoupeScreenState extends State<LoupeScreen> {
  bool _loading = true;
  Object? _error;
  final Map<String, Uint8List> _loadedBytes = {};

  LoupeHudMode _hudMode = LoupeHudMode.compact;

  bool _showFocusMask = false;
  bool _focusMaskBusy = false;
  final Map<String, Uint8List?> _focusMaskPngByKey = {};
  Color _focusMaskColor = const Color(0xFF00D084); // Pro Mode green accent
  double _focusMaskOpacity = 0.25; // Pro Mode 0.25 opacity

  bool _showFocusPoint = true;
  bool _showHistogram = true;
  final Map<String, int> _imageWidths = {};
  final Map<String, int> _imageHeights = {};

  // Keyboard focus management
  late final FocusNode _focusNode;
  int _activePaneIndex = 0;
  bool _showDebugOverlay = false;

  bool _syncEnabled = false; // Changed: Default to false
  final List<TransformationController> _controllers = [];

  // For relative sync: track the start matrix when sync is enabled
  final List<Matrix4> _initialMatrices = [];

  late List<bool> _isBests;

  @override
  void initState() {
    super.initState();
    _isBests = List.of(widget.isBests);
    _focusNode = FocusNode();
    for (var i = 0; i < widget.items.length; i++) {
      _controllers.add(TransformationController());
    }
    for (final item in widget.items) {
      _loadedBytes[item.key] = item.displayBytes;
    }
    _loading = false;
    _loadAll();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(LoupeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.isBests, widget.isBests)) {
      _isBests = List.of(widget.isBests);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _onInteractionUpdate(int sourceIndex) {
    if (!_syncEnabled) return;
    if (_initialMatrices.isEmpty || sourceIndex >= _initialMatrices.length) {
      return;
    }

    final currentMatrix = _controllers[sourceIndex].value;
    final startMatrix = _initialMatrices[sourceIndex];

    if (startMatrix.determinant() == 0) {
      return;
    }

    // Relative transformation: Delta = Current * Inverse(Start)
    final delta = currentMatrix * Matrix4.inverted(startMatrix);

    for (var i = 0; i < _controllers.length; i++) {
      if (i != sourceIndex) {
        // NewMatrix = Delta * InitialMatrixOfOther
        _controllers[i].value = delta * _initialMatrices[i];
      }
    }
  }

  Future<void> _loadAll() async {
    try {
      await Future.wait(widget.items.map((item) async {
        final bytes = await _loadFull(item);
        if (bytes != null && mounted) {
          setState(() {
            _loadedBytes[item.key] = bytes;
          });
        }
      }));
    } catch (e) {
      _error = e;
    }
  }

  Future<void> _ensureFocusMasks() async {
    if (_focusMaskBusy) return;
    setState(() => _focusMaskBusy = true);
    try {
      for (final item in widget.items) {
        final key = item.key;
        if (_focusMaskPngByKey.containsKey(key)) continue;

        // Check if the mask is already cached in memory for this session
        if (LoupeScreen._sessionMaskCache.containsKey(key)) {
          _focusMaskPngByKey[key] = LoupeScreen._sessionMaskCache[key];
          continue;
        }

        final b = _loadedBytes[key];
        if (b == null) {
          _focusMaskPngByKey[key] = null;
          continue;
        }
        final png = await compute(focusMaskPngFromBytes, b);
        if (!mounted) return;
        _focusMaskPngByKey[key] = png;

        // Store the computed mask in the session cache
        if (png != null) {
          LoupeScreen._sessionMaskCache[key] = png;
        }
      }
    } finally {
      if (mounted) setState(() => _focusMaskBusy = false);
    }
  }

  final List<Color> _maskColors = [
    const Color(0xFF00D084),
    const Color(0xFF3A86FF),
    const Color(0xFFFFBE0B),
    const Color(0xFFFF006E),
    Colors.white,
  ];

  void _cycleMaskColor() {
    final idx = _maskColors.indexOf(_focusMaskColor);
    final nextIdx = (idx + 1) % _maskColors.length;
    setState(() {
      _focusMaskColor = _maskColors[nextIdx];
    });
  }

  Future<void> _toggleFocusMask() async {
    final next = !_showFocusMask;
    setState(() => _showFocusMask = next);
    if (next) await _ensureFocusMasks();
  }

  Future<Uint8List?> _loadFull(PhotoEntry e) async {
    if (e.filePath != null) {
      final f = File(e.filePath!);
      if (await f.exists()) {
        return await f.readAsBytes();
      }
    }
    return e.displayBytes;
  }

  void _cycleHudMode() {
    setState(() {
      switch (_hudMode) {
        case LoupeHudMode.compact:
          _hudMode = LoupeHudMode.detailed;
          break;
        case LoupeHudMode.detailed:
          _hudMode = LoupeHudMode.clean;
          break;
        case LoupeHudMode.clean:
          _hudMode = LoupeHudMode.compact;
          break;
      }
    });
  }

  void _toggleHistogram() {
    setState(() {
      _showHistogram = !_showHistogram;
    });
  }

  void _toggleSync() {
    setState(() {
      _syncEnabled = !_syncEnabled;
      if (_syncEnabled) {
        // Snapshot current positions as initial
        _initialMatrices.clear();
        for (final c in _controllers) {
          _initialMatrices.add(c.value.clone());
        }
      }
    });
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final count = widget.items.length;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_activePaneIndex > 0) {
        setState(() {
          _activePaneIndex--;
        });
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (_activePaneIndex < count - 1) {
        setState(() {
          _activePaneIndex++;
        });
      }
      return KeyEventResult.handled;
    }

    // 数字キー 1〜4 でアクティブペイン選択切り替え
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      if (count > 0) setState(() => _activePaneIndex = 0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      if (count > 1) setState(() => _activePaneIndex = 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      if (count > 2) setState(() => _activePaneIndex = 2);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      if (count > 3) setState(() => _activePaneIndex = 3);
      return KeyEventResult.handled;
    }

    // I キー: HUD表示モード切り替え (Compact → Detailed → Clean)
    if (key == LogicalKeyboardKey.keyI) {
      _cycleHudMode();
      return KeyEventResult.handled;
    }

    // H キー: ヒストグラム表示トグル
    if (key == LogicalKeyboardKey.keyH) {
      _toggleHistogram();
      return KeyEventResult.handled;
    }

    // M キー: フォーカスマスク表示トグル
    if (key == LogicalKeyboardKey.keyM) {
      _toggleFocusMask();
      return KeyEventResult.handled;
    }

    // S キー: 連動拡大トグル
    if (key == LogicalKeyboardKey.keyS) {
      _toggleSync();
      return KeyEventResult.handled;
    }

    // Z キー: ピント位置へのズーム / リセット
    if (key == LogicalKeyboardKey.keyZ) {
      _zoomActivePaneToFocusPoint();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.space) {
      if (_activePaneIndex >= 0 && _activePaneIndex < count) {
        final itemKey = widget.items[_activePaneIndex].key;
        final currentlySelected =
            widget.initialSelectedForDelete?.contains(itemKey) ?? false;
        widget.onToggleDelete?.call(itemKey, !currentlySelected);
        setState(() {});
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.keyB) {
      if (_activePaneIndex >= 0 && _activePaneIndex < count) {
        final itemKey = widget.items[_activePaneIndex].key;
        widget.onSetBest?.call(itemKey);
        setState(() {
          for (var i = 0; i < _isBests.length; i++) {
            _isBests[i] = (widget.items[i].key == itemKey);
          }
        });
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompactAppBar = screenWidth < 720;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isCompactAppBar
                ? '🔍 比較モード'
                : '🔍 比較モード  (${_syncEnabled ? "🔒 同期ロック ON" : "🔓 同期ロック OFF"})',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          actions: [
            // HUD モード切替（Compact / Detailed / Clean）
            IconButton(
              tooltip: 'HUD切替: ${_hudMode.label} [I]',
              onPressed: _cycleHudMode,
              icon: Icon(
                _hudMode.icon,
                color: _hudMode == LoupeHudMode.clean
                    ? Colors.white38
                    : (_hudMode == LoupeHudMode.compact
                        ? Colors.cyanAccent
                        : Colors.amberAccent),
              ),
            ),
            // ピント位置マーク
            IconButton(
              tooltip: _showFocusPoint ? 'ピント位置マークを隠す' : 'ピント位置マークを表示',
              onPressed: () => setState(() => _showFocusPoint = !_showFocusPoint),
              icon: Icon(
                _showFocusPoint ? Icons.filter_center_focus : Icons.center_focus_weak,
                color: _showFocusPoint ? const Color(0xFF00E676) : null,
              ),
            ),
            // ヒストグラム表示トグル
            IconButton(
              tooltip: _showHistogram ? 'ヒストグラムを隠す [H]' : 'ヒストグラムを表示 [H]',
              onPressed: _toggleHistogram,
              icon: Icon(
                _showHistogram ? Icons.bar_chart : Icons.bar_chart_outlined,
                color: _showHistogram ? Colors.cyanAccent : null,
              ),
            ),
            // ピント位置へズーム / リセット
            IconButton(
              tooltip: 'ピント位置へズーム / リセット [Z]',
              onPressed: _zoomActivePaneToFocusPoint,
              icon: const Icon(Icons.zoom_in_map, color: Colors.amberAccent),
            ),
            // フォーカスマスク
            IconButton(
              tooltip: _showFocusMask ? 'フォーカスマスクを隠す [M]' : 'フォーカスマスクを表示 [M]',
              onPressed: _loading || _error != null ? null : _toggleFocusMask,
              icon: _focusMaskBusy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_showFocusMask ? Icons.blur_off : Icons.blur_on),
            ),
            if (_showFocusMask) ...[
              IconButton(
                tooltip: 'マスクの色を変更',
                icon: Icon(Icons.color_lens, color: _focusMaskColor),
                onPressed: _cycleMaskColor,
              ),
              if (!isCompactAppBar) ...[
                const SizedBox(width: 4),
                SizedBox(
                  width: 80,
                  child: Slider(
                    value: _focusMaskOpacity,
                    onChanged: (v) => setState(() => _focusMaskOpacity = v),
                  ),
                ),
              ],
            ],
            // 連動拡大
            if (isCompactAppBar)
              IconButton(
                tooltip: '連動拡大: ${_syncEnabled ? "ON" : "OFF"} [S]',
                icon: Icon(
                  _syncEnabled ? Icons.sync : Icons.sync_disabled,
                  color: _syncEnabled ? Colors.cyanAccent : null,
                ),
                onPressed: _toggleSync,
              )
            else
              Row(
                children: [
                  const Text('連動拡大', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: _syncEnabled,
                    onChanged: (_) => _toggleSync(),
                  ),
                ],
              ),
            if (!isCompactAppBar)
              IconButton(
                tooltip: 'デバッグ表示を切り替え',
                onPressed: () =>
                    setState(() => _showDebugOverlay = !_showDebugOverlay),
                icon: Icon(
                  _showDebugOverlay
                      ? Icons.bug_report
                      : Icons.bug_report_outlined,
                  color: _showDebugOverlay ? Colors.redAccent : null,
                ),
              ),
            const SizedBox(width: 8),
          ],
        ),
        backgroundColor: Colors.transparent,
        body: GlobalBackground(
          child: _buildBody(),
        ),
        bottomNavigationBar: _buildBottomBar(),
      ),
    );
  }

  void _zoomActivePaneToFocusPoint() {
    if (_activePaneIndex < 0 || _activePaneIndex >= widget.items.length) return;
    final item = widget.items[_activePaneIndex];
    final controller = _controllers[_activePaneIndex];

    Offset? pt;
    final w = _imageWidths[item.key];
    final h = _imageHeights[item.key];
    if (item.portrait.hasFace &&
        item.portrait.faceW > 0 &&
        item.portrait.faceH > 0 &&
        w != null &&
        h != null) {
      pt = Offset(
        (item.portrait.faceX + item.portrait.faceW * 0.5) / w,
        (item.portrait.faceY + item.portrait.faceH * 0.35) / h,
      );
    } else {
      pt = item.focusPoint;
    }
    if (pt == null) return;

    if (controller.value.getMaxScaleOnAxis() > 1.2) {
      // 既に拡大中の場合は等倍へリセット
      controller.value = Matrix4.identity();
    } else {
      // ピント位置を中心にして3.0倍に拡大
      const scale = 3.0;
      final renderBox = context.findRenderObject() as RenderBox?;
      final viewport = renderBox?.size ?? const Size(800, 600);
      final tx = (viewport.width / 2) - (pt.dx * viewport.width * scale);
      final ty = (viewport.height / 2) - (pt.dy * viewport.height * scale);
      final m = Matrix4.identity()
        ..translateByDouble(tx, ty, 0.0, 1.0)
        ..scaleByDouble(scale, scale, 1.0, 1.0);
      controller.value = m;
    }
    _onInteractionUpdate(_activePaneIndex);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('読み込み失敗: $_error'));
    }
    if (_loadedBytes.isEmpty) {
      return const Center(child: Text('画像が読み込めませんでした'));
    }

    final size = MediaQuery.of(context).size;
    final isPortrait = size.height > size.width;

    final count = widget.items.length;
    if (count <= 3) {
      if (isPortrait) {
        return Column(
          children: [
            for (int i = 0; i < count; i++) Expanded(child: _buildPane(i)),
          ],
        );
      } else {
        return Row(
          children: [
            for (int i = 0; i < count; i++) Expanded(child: _buildPane(i)),
          ],
        );
      }
    } else {
      // 4 items: 2x2 grid
      return Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildPane(0)),
                Expanded(child: _buildPane(1)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildPane(2)),
                Expanded(child: _buildPane(3)),
              ],
            ),
          ),
        ],
      );
    }
  }

  Widget _buildBottomBar() {
    if (_loading || _error != null || widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_activePaneIndex < 0 || _activePaneIndex >= widget.items.length) {
      return const SizedBox.shrink();
    }

    final item = widget.items[_activePaneIndex];
    final key = item.key;
    final isBest = _isBests[_activePaneIndex];
    final selectedForDelete =
        widget.initialSelectedForDelete?.contains(key) ?? false;

    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 500;

    return SafeArea(
      child: Container(
        margin: EdgeInsets.fromLTRB(
          isNarrow ? 8 : 16,
          0,
          isNarrow ? 8 : 16,
          isNarrow ? 6 : 12,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: isNarrow ? 10 : 16,
          vertical: isNarrow ? 6 : 10,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFF2C2C2E), width: 1),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Active photo indicator info
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${isNarrow ? "" : "選択中: "}${_getFileName(item)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: isNarrow ? 12 : 13,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '鮮明度: ${widget.scores[_activePaneIndex].toStringAsFixed(0)}  │  ペイン #${_activePaneIndex + 1}/${widget.items.length}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF8A8A8E),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Toggle Delete button
                InkWell(
                  onTap: () {
                    widget.onToggleDelete?.call(key, !selectedForDelete);
                    setState(() {});
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: selectedForDelete
                          ? const Color(0xFFFF006E).withValues(alpha: 0.2)
                          : const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: selectedForDelete
                            ? const Color(0xFFFF006E)
                            : const Color(0xFF3A3A3C),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          selectedForDelete ? Icons.delete_forever : Icons.delete_outline,
                          color: selectedForDelete ? const Color(0xFFFF006E) : Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isNarrow ? '削除' : '削除候補',
                          style: TextStyle(
                            color: selectedForDelete ? const Color(0xFFFF006E) : Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Toggle Best button
                InkWell(
                  onTap: () {
                    widget.onSetBest?.call(key);
                    setState(() {
                      for (var j = 0; j < _isBests.length; j++) {
                        _isBests[j] = (j == _activePaneIndex);
                      }
                    });
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: isBest
                          ? const Color(0xFFFFBE0B).withValues(alpha: 0.2)
                          : const Color(0xFF2C2C2E),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isBest ? const Color(0xFFFFBE0B) : const Color(0xFF3A3A3C),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isBest ? Icons.star : Icons.star_border,
                          color: isBest ? const Color(0xFFFFBE0B) : Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isBest ? 'Best' : 'Bestに設定',
                          style: TextStyle(
                            color: isBest ? const Color(0xFFFFBE0B) : Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Section 2.3 アクションフッター: [⬅ 画像を入れ替え] [📊 比較スコア] [🔄 マスク] [✖ 一括解除]
            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 28),
                    side: const BorderSide(color: Color(0xFF2C2C2E)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: () {
                    setState(() {
                      _activePaneIndex = (_activePaneIndex + 1) % widget.items.length;
                    });
                  },
                  icon: const Icon(Icons.swap_horiz, size: 14, color: Color(0xFF8A8A8E)),
                  label: const Text('入替', style: TextStyle(fontSize: 11, color: Colors.white)),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 28),
                    side: const BorderSide(color: Color(0xFF2C2C2E)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        backgroundColor: const Color(0xFF1C1C1E),
                        title: const Text('比較スコア一覧', style: TextStyle(color: Colors.white, fontSize: 15)),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (int i = 0; i < widget.items.length; i++)
                              ListTile(
                                dense: true,
                                leading: Text('#${i + 1}', style: const TextStyle(color: Color(0xFF3A86FF), fontWeight: FontWeight.bold)),
                                title: Text(_getFileName(widget.items[i]), style: const TextStyle(color: Colors.white, fontSize: 12)),
                                trailing: Text(
                                  '${widget.scores[i].toStringAsFixed(0)}点',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: _isBests[i] ? const Color(0xFFFFBE0B) : Colors.white70,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('閉じる'),
                          ),
                        ],
                      ),
                    );
                  },
                  icon: const Icon(Icons.bar_chart, size: 14, color: Color(0xFFFFBE0B)),
                  label: const Text('比較スコア', style: TextStyle(fontSize: 11, color: Colors.white)),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 28),
                    side: BorderSide(
                      color: _showFocusMask ? const Color(0xFF00D084) : const Color(0xFF2C2C2E),
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: _toggleFocusMask,
                  icon: Icon(
                    _showFocusMask ? Icons.blur_on : Icons.blur_off,
                    size: 14,
                    color: _showFocusMask ? const Color(0xFF00D084) : const Color(0xFF8A8A8E),
                  ),
                  label: Text(
                    'マスク ${_showFocusMask ? "ON" : "OFF"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: _showFocusMask ? const Color(0xFF00D084) : Colors.white,
                    ),
                  ),
                ),
                const Spacer(),
                // 一括解除
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: const Size(0, 28),
                  ),
                  onPressed: () {
                    for (final item in widget.items) {
                      widget.onToggleDelete?.call(item.key, false);
                    }
                    setState(() {});
                  },
                  icon: const Icon(Icons.clear_all, size: 14, color: Color(0xFFFF006E)),
                  label: const Text('一括解除', style: TextStyle(fontSize: 11, color: Color(0xFFFF006E))),
                ),
              ],
            ),
          ],
        ),
      ),
    );

  }

  String _getFileName(PhotoEntry item) {
    if (item.filePath != null) {
      return p.basename(item.filePath!);
    }
    if (item.key.startsWith('file:')) {
      return p.basename(item.key.substring(5));
    }
    return item.key;
  }

  Widget _buildPane(int index) {
    if (index >= widget.items.length) return const SizedBox.shrink();
    final item = widget.items[index];
    final key = item.key;
    final bytes = _loadedBytes[key];
    if (bytes == null) {
      return const Center(child: Text('画像読み込み失敗'));
    }
    return _ZoomPane(
      item: item,
      paneIndex: index,
      totalPanes: widget.items.length,
      hudMode: _hudMode,
      bytes: bytes,
      maskPng: _focusMaskPngByKey[key],
      showFocusMask: _showFocusMask,
      maskColor: _focusMaskColor,
      maskOpacity: _focusMaskOpacity,
      showFocusPoint: _showFocusPoint,
      showHistogram: _showHistogram,
      title: _getFileName(item),
      score: widget.scores[index],
      controller: _controllers[index],
      onInteractionUpdate: () => _onInteractionUpdate(index),
      isFocused: index == _activePaneIndex,
      onTap: () {
        setState(() {
          _activePaneIndex = index;
        });
      },
      showDebugOverlay: _showDebugOverlay,
      onImageSizeResolved: (w, h) {
        _imageWidths[key] = w;
        _imageHeights[key] = h;
      },
      onZoomToPoint: () {
        setState(() => _activePaneIndex = index);
        _zoomActivePaneToFocusPoint();
      },
    );
  }
}

class _ZoomPane extends StatefulWidget {
  const _ZoomPane({
    required this.item,
    required this.paneIndex,
    required this.totalPanes,
    required this.hudMode,
    required this.bytes,
    required this.maskPng,
    required this.showFocusMask,
    required this.maskColor,
    required this.maskOpacity,
    required this.showFocusPoint,
    required this.showHistogram,
    required this.title,
    required this.score,
    required this.controller,
    required this.onInteractionUpdate,
    required this.isFocused,
    required this.onTap,
    required this.showDebugOverlay,
    required this.onImageSizeResolved,
    required this.onZoomToPoint,
  });

  final PhotoEntry item;
  final int paneIndex;
  final int totalPanes;
  final LoupeHudMode hudMode;
  final Uint8List bytes;
  final Uint8List? maskPng;
  final bool showFocusMask;
  final Color maskColor;
  final double maskOpacity;
  final bool showFocusPoint;
  final bool showHistogram;
  final String title;
  final double score;
  final TransformationController controller;
  final VoidCallback onInteractionUpdate;
  final bool isFocused;
  final VoidCallback onTap;
  final bool showDebugOverlay;
  final void Function(int width, int height) onImageSizeResolved;
  final VoidCallback onZoomToPoint;

  @override
  State<_ZoomPane> createState() => _ZoomPaneState();
}

class _ZoomPaneState extends State<_ZoomPane> {
  int? _imageWidth;
  int? _imageHeight;

  @override
  void initState() {
    super.initState();
    _resolveImageSize();
  }

  @override
  void didUpdateWidget(_ZoomPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) {
      _resolveImageSize();
    }
  }

  void _resolveImageSize() {
    decodeImageFromList(widget.bytes).then((codec) {
      if (mounted) {
        setState(() {
          _imageWidth = codec.width;
          _imageHeight = codec.height;
        });
        widget.onImageSizeResolved(codec.width, codec.height);
      }
    }).catchError((_) {});
  }

  List<Widget> _buildGridOverlay(double w, double h) {
    final sharps = widget.item.debugGridSharps;
    if (sharps == null || sharps.length != 16) return [];

    final indexValues = List.generate(16, (i) => MapEntry(i, sharps[i]))
      ..sort((a, b) => b.value.compareTo(a.value));
    final top4Indices = indexValues.take(4).map((e) => e.key).toSet();

    final cellW = w / 4.0;
    final cellH = h / 4.0;
    final widgets = <Widget>[];

    for (int y = 0; y < 4; y++) {
      for (int x = 0; x < 4; x++) {
        final idx = y * 4 + x;
        final val = sharps[idx];
        final isTop4 = top4Indices.contains(idx);

        widgets.add(
          Positioned(
            left: x * cellW,
            top: y * cellH,
            width: cellW,
            height: cellH,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isTop4
                      ? Colors.green.withValues(alpha: 0.6)
                      : Colors.white24,
                  width: isTop4 ? 2.0 : 0.8,
                ),
                color: isTop4
                    ? Colors.green.withValues(alpha: 0.08)
                    : Colors.transparent,
              ),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    val.toStringAsFixed(0),
                    style: TextStyle(
                      color: isTop4 ? Colors.greenAccent : Colors.white70,
                      fontSize: 9,
                      fontWeight: isTop4 ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
    }
    return widgets;
  }

  List<Widget> _buildObjectsOverlay(double w, double h) {
    final list = widget.item.semanticObjects;
    return list.map((obj) {
      final left = obj.x * w;
      final top = obj.y * h;
      final width = obj.w * w;
      final height = obj.h * h;

      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.cyanAccent, width: 2.0),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: -16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  color: Colors.cyanAccent.withValues(alpha: 0.85),
                  child: Text(
                    obj.label,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }

  Widget _buildFaceOverlay(double w, double h) {
    final imgW = _imageWidth!;
    final imgH = _imageHeight!;
    final p = widget.item.portrait;
    final fx = p.faceX / imgW * w;
    final fy = p.faceY / imgH * h;
    final fw = p.faceW / imgW * w;
    final fh = p.faceH / imgH * h;

    return Positioned(
      left: fx,
      top: fy,
      width: fw,
      height: fh,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.orangeAccent, width: 2.0),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: -16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.orangeAccent.withValues(alpha: 0.85),
                child: const Text(
                  'FACE',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ピント位置マーク（カメラのAFフレーム / 瞳AFレティクル）
  Widget _buildFocusMarker(double w, double h) {
    if (!widget.showFocusPoint) return const SizedBox.shrink();

    Offset? pt;
    bool isEyeAf = false;
    final item = widget.item;
    final p = item.portrait;
    if (p.hasFace &&
        p.faceW > 0 &&
        p.faceH > 0 &&
        _imageWidth != null &&
        _imageHeight != null) {
      final cx = (p.faceX + p.faceW * 0.5) / _imageWidth!;
      final cy = (p.faceY + p.faceH * 0.35) / _imageHeight!;
      pt = Offset(cx, cy);
      isEyeAf = true;
    } else {
      pt = item.focusPoint;
    }
    if (pt == null) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final posX = pt.dx * w;
    final posY = pt.dy * h;
    const boxSize = 44.0;
    final maxLeft = (w - boxSize) < 0.0 ? 0.0 : (w - boxSize);
    final maxTop = (h - boxSize) < 0.0 ? 0.0 : (h - boxSize);

    return Positioned(
      left: (posX - boxSize / 2).clamp(0.0, maxLeft),
      top: (posY - boxSize / 2).clamp(0.0, maxTop),
      width: boxSize,
      height: boxSize,
      child: GestureDetector(
        onTap: widget.onZoomToPoint,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: isEyeAf ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
              width: 2.0,
            ),
            borderRadius: BorderRadius.circular(4),
            color: (isEyeAf ? const Color(0xFF00E676) : const Color(0xFF00E5FF))
                .withValues(alpha: 0.12),
          ),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // 中心十字ドット
              Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: isEyeAf ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
                  shape: BoxShape.circle,
                ),
              ),
              // 上部ラベル
              Positioned(
                top: -15,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: (isEyeAf ? const Color(0xFF00E676) : const Color(0xFF00E5FF))
                        .withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    isEyeAf ? '瞳 AF' : 'FOCUS',
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaneHeader(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final exif = widget.item.exif;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      color: widget.isFocused
          ? colorScheme.primaryContainer.withValues(alpha: 0.1)
          : Colors.transparent,
      child: Row(
        children: [
          // ペイン番号インジケータ [1]
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
            decoration: BoxDecoration(
              color: widget.isFocused ? colorScheme.primary : Colors.white24,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '${widget.paneIndex + 1}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: widget.isFocused ? colorScheme.onPrimary : Colors.white,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // ファイル名
          Flexible(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: widget.isFocused
                        ? colorScheme.onPrimaryContainer
                        : Colors.white,
                    fontWeight: widget.isFocused ? FontWeight.bold : FontWeight.w500,
                  ),
            ),
          ),
          // コンパクトモード時: 写真上ではなくヘッダーに露出値と鮮鋭度をドッキング表示
          if (widget.hudMode == LoupeHudMode.compact) ...[
            const SizedBox(width: 8),
            _buildCompactHeaderChips(exif, widget.score),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactHeaderChips(ExifSummary? exif, double score) {
    final items = <String>[];
    if (exif?.shutter != null) items.add(exif!.shutter!);
    if (exif?.fNumber != null) items.add('F${exif!.fNumber!}');
    if (exif?.iso != null) items.add('ISO${exif!.iso!}');
    if (exif?.focalLength != null) items.add(exif!.focalLength!);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (items.isNotEmpty)
          Text(
            items.join(' · '),
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            'S: ${score.toStringAsFixed(0)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  /// 重なり防止＆HUDモード連動オーバーレイ
  Widget _buildOverlays(BoxConstraints constraints) {
    final showHisto = widget.showHistogram && widget.item.histogram.isNotEmpty;
    final showDebug = widget.showDebugOverlay;

    // クリーンモード: デバッグオーバーレイON時のみデバッグカードを表示、それ以外は非表示
    if (widget.hudMode == LoupeHudMode.clean) {
      if (!showDebug) return const SizedBox.shrink();
      return Positioned(
        left: 10,
        top: 10,
        right: 10,
        child: Align(
          alignment: Alignment.topLeft,
          child: _buildDebugExplanationCard(maxWidth: constraints.maxWidth - 20),
        ),
      );
    }

    // コンパクトモード: ヘッダーに主要露出値は表示済み。
    // ヒストグラムがONなら右上、デバッグがONなら左上に配置
    if (widget.hudMode == LoupeHudMode.compact) {
      if (!showHisto && !showDebug) return const SizedBox.shrink();
      final paneWidth = constraints.maxWidth;
      return Positioned(
        left: 10,
        top: 10,
        right: 10,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (showDebug)
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: paneWidth >= 500 ? 360 : 280),
                  child: _buildDebugExplanationCard(
                    maxWidth: paneWidth >= 500 ? 360 : 280,
                  ),
                ),
              )
            else
              const Spacer(),
            if (showHisto) ...[
              const SizedBox(width: 8),
              _buildHistogramContent(),
            ],
          ],
        ),
      );
    }

    // 詳細モード (Detailed):
    // ペイン幅に応じてレイアウトを動的に調整し、絶対に衝突・重なり合わない構造
    final paneWidth = constraints.maxWidth;

    return Positioned(
      left: 10,
      top: 10,
      right: 10,
      child: paneWidth >= 480
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: _buildCameraHudContent(),
                  ),
                ),
                if (showHisto) ...[
                  const SizedBox(width: 10),
                  _buildHistogramContent(),
                ],
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildCameraHudContent(),
                if (showHisto) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.topRight,
                    child: _buildHistogramContent(),
                  ),
                ],
              ],
            ),
    );
  }

  /// カメラ情報 HUDカード
  Widget _buildCameraHudContent() {
    final exif = widget.item.exif;
    final hasCameraInfo = exif?.cameraModel != null || exif?.lensModel != null;
    final isShakeRisk = _isCameraShakeRisk(exif);

    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 機材名（カメラ + レンズ）
          if (hasCameraInfo) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.photo_camera, size: 12, color: Colors.cyanAccent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    [
                      if (exif?.cameraModel != null) exif!.cameraModel!,
                      if (exif?.lensModel != null) exif!.lensModel!,
                    ].join('  /  '),
                    style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
          ],
          // 撮影パラメーター（焦点距離・絞り・SS・ISO・EV）
          Wrap(
            spacing: 5,
            runSpacing: 3,
            children: [
              if (exif?.focalLength != null)
                _buildParamChip(Icons.straighten, exif!.focalLength!),
              if (exif?.fNumber != null)
                _buildParamChip(Icons.camera, 'F${exif!.fNumber!}'),
              if (exif?.shutter != null)
                _buildParamChip(Icons.timer, exif!.shutter!),
              if (exif?.iso != null)
                _buildParamChip(Icons.iso, 'ISO${exif!.iso!}'),
              if (exif?.exposureBias != null)
                _buildParamChip(Icons.exposure, exif!.exposureBias!),
            ],
          ),
          const SizedBox(height: 4),
          // スコア & 手ブレ警告表示
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ピント値: ${widget.score.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (isShakeRisk) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.25),
                    border: Border.all(color: Colors.amber, width: 0.8),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 10, color: Colors.amber),
                      SizedBox(width: 2),
                      Text(
                        '手ブレ注意 (低SS)',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          // デバッグ表示（XAI・判定理由・メトリクス詳細）
          if (widget.showDebugOverlay) ...[
            const SizedBox(height: 6),
            _buildDebugExplanationCard(maxWidth: 340),
            const SizedBox(height: 4),
            Text(
              '解像度: ${_imageWidth ?? "?"} x ${_imageHeight ?? "?"}',
              style: const TextStyle(color: Colors.white70, fontSize: 8.5),
            ),
          ],
        ],
      ),
    );
  }

  /// AIスコア・グループ判定理由カード（XAI / デバッグ可視化）
  Widget _buildDebugExplanationCard({double maxWidth = 340}) {
    final sExp = widget.item.scoreExplanation;
    final gExp = widget.item.groupExplanation;

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: const Color(0xFF0B132B).withValues(alpha: 0.92), // Deep Navy Card
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.7), width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: タイトル & 総合点バッジ
          Row(
            children: [
              const Icon(Icons.psychology_outlined, size: 13, color: Colors.redAccent),
              const SizedBox(width: 4),
              const Text(
                'AI判定・スコア算出根拠',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (sExp != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6), width: 0.8),
                  ),
                  child: Text(
                    '総合 ${(sExp.totalScore * 100).toStringAsFixed(1)}点',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Container(height: 0.8, color: Colors.white12),
          const SizedBox(height: 5),

          // 1. グループ化判定理由 (Grouping Explanation)
          if (gExp != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.tealAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                  child: Text(
                    gExp.matchType,
                    style: const TextStyle(
                      color: Colors.tealAccent,
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    gExp.description,
                    style: const TextStyle(color: Colors.white, fontSize: 9),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                if (gExp.category != null)
                  _buildDebugTag('区分', gExp.category!),
                if (gExp.diffSeconds != null)
                  _buildDebugTag('Δt', '${gExp.diffSeconds!.toStringAsFixed(1)}s'),
                if (gExp.pHashDistance != null)
                  _buildDebugTag('pHash距離', '${gExp.pHashDistance}'),
                if (gExp.colorDistance != null)
                  _buildDebugTag('色距離', gExp.colorDistance!.toStringAsFixed(3)),
                if (gExp.orbMatches != null)
                  _buildDebugTag('ORB一致', '${gExp.orbMatches}点'),
                if (gExp.inliers != null)
                  _buildDebugTag('幾何Inlier', '${gExp.inliers}点'),
                if (gExp.orbInlierRatio != null)
                  _buildDebugTag('Inlier率', '${(gExp.orbInlierRatio! * 100).toStringAsFixed(1)}%'),
                if (gExp.embeddingSimilarity != null)
                  _buildDebugTag('埋め込み', '${(gExp.embeddingSimilarity! * 100).toStringAsFixed(1)}%'),
                if (gExp.cropPair != null)
                  _buildDebugTag('クロップ', gExp.cropPair!),
                if (gExp.semanticMatch)
                  _buildDebugTag('被写体', '一致'),
                if (gExp.confidence > 0)
                  _buildDebugTag('結合信頼度', '${(gExp.confidence * 100).toStringAsFixed(1)}%'),
                if (gExp.needsReview)
                  _buildDebugTag('⚠️', '要確認'),
                if (gExp.referenceKey != null)
                  _buildDebugTag(
                    '基準写真',
                    gExp.referenceKey!.split(RegExp(r'[\\/]')).last,
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Container(height: 0.8, color: Colors.white12),
            const SizedBox(height: 5),
          ],

          // 2. スコア算出理由 (Score Calculation)
          if (sExp != null) ...[
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                  child: Text(
                    sExp.ruleName,
                    style: const TextStyle(
                      color: Colors.amberAccent,
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              sExp.formulaText,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 8.5,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                _buildDebugTag('生鮮鋭度', sExp.rawSharpness.toStringAsFixed(0)),
                _buildDebugTag('ISO補正後', sExp.effectiveSharpness.toStringAsFixed(0)),
                _buildDebugTag('正規化鮮鋭度', '${(sExp.normalizedSharpness * 100).toStringAsFixed(1)}%'),
                _buildDebugTag('露出点', '${(sExp.exposureScore * 100).toStringAsFixed(1)}%'),
                if (sExp.faceQualityScore > 0)
                  _buildDebugTag('顔品質点', '${(sExp.faceQualityScore * 100).toStringAsFixed(1)}%'),
              ],
            ),
          ] else ...[
            Text(
              '生鮮鋭度: ${widget.item.sharpness.toStringAsFixed(0)} | 露出: ${widget.item.exposureScore.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 8.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDebugTag(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2.5),
        border: Border.all(color: Colors.white12, width: 0.5),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(color: Colors.white70, fontSize: 8),
      ),
    );
  }

  Widget _buildParamChip(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  bool _isCameraShakeRisk(ExifSummary? exif) {
    if (exif == null) return false;
    final flStr = exif.focalLength;
    final ssStr = exif.shutter;
    if (flStr == null || ssStr == null) return false;

    final flMatch = RegExp(r'\d+').firstMatch(flStr);
    if (flMatch == null) return false;
    final fl = double.tryParse(flMatch.group(0)!);
    if (fl == null || fl <= 0) return false;

    double? ss;
    if (ssStr.contains('/')) {
      final parts = ssStr.split('/');
      final num = double.tryParse(parts[0]);
      final den = double.tryParse(parts[1]);
      if (num != null && den != null && den > 0) ss = num / den;
    } else {
      ss = double.tryParse(ssStr);
    }
    if (ss == null) return false;

    // 手ブレ限界速度: SS > 1/焦点距離 * 1.25
    final limit = 1.0 / fl;
    return ss > limit * 1.25;
  }

  /// ヒストグラムカード
  Widget _buildHistogramContent() {
    return Container(
      width: 110,
      height: 64,
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'HISTOGRAM',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                'Luma',
                style: TextStyle(
                  color: Colors.cyanAccent,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: CustomPaint(
              painter: _HistogramPainter(
                widget.item.histogram,
                barColor: const Color(0xFF38BDF8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTap: widget.onZoomToPoint, // ダブルタップで等倍 / 3倍ズーム
      child: Container(
        margin: const EdgeInsets.all(6),
        child: GlassContainer(
          borderRadius: BorderRadius.circular(20),
          borderColor: widget.isFocused ? colorScheme.primary : colorScheme.outlineVariant.withValues(alpha: 0.25),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _buildPaneHeader(context),
            Expanded(
              child: LayoutBuilder(
                builder: (context, paneConstraints) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: InteractiveViewer(
                          transformationController: widget.controller,
                          minScale: 1,
                          maxScale: 12,
                          onInteractionUpdate: (_) => widget.onInteractionUpdate(),
                          child: Center(
                            child: Stack(
                              alignment: Alignment.center,
                              fit: StackFit.passthrough,
                              children: [
                                Image(
                                  image: ResizeImage(
                                    MemoryImage(widget.bytes),
                                    width: 3840,
                                    height: 3840,
                                    policy: ResizeImagePolicy.fit,
                                  ),
                                  filterQuality: FilterQuality.high,
                                ),
                                if (widget.showFocusMask && widget.maskPng != null)
                                  Opacity(
                                    opacity: widget.maskOpacity,
                                    child: Image.memory(
                                      widget.maskPng!,
                                      filterQuality: FilterQuality.low,
                                      color: widget.maskColor,
                                      colorBlendMode: BlendMode.srcIn,
                                    ),
                                  ),
                                // ピント位置マークおよびオーバーレイ枠（画像サイズに追従）
                                Positioned.fill(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final w = constraints.maxWidth;
                                      final h = constraints.maxHeight;
                                      if (w <= 0 || h <= 0) {
                                        return const SizedBox.shrink();
                                      }
                                      return Stack(
                                        fit: StackFit.passthrough,
                                        children: [
                                          if (widget.showFocusPoint)
                                            _buildFocusMarker(w, h),
                                          if (widget.showDebugOverlay) ...[
                                            if (widget.item.debugGridSharps != null &&
                                                widget.item.debugGridSharps!.length == 16)
                                              ..._buildGridOverlay(w, h),
                                            if (widget.item.semanticObjects.isNotEmpty)
                                              ..._buildObjectsOverlay(w, h),
                                            if (widget.item.portrait.hasFace &&
                                                widget.item.portrait.faceW > 0 &&
                                                widget.item.portrait.faceH > 0 &&
                                                _imageWidth != null &&
                                                _imageHeight != null)
                                              _buildFaceOverlay(w, h),
                                          ],
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 重なり防止＆HUDモード連動オーバーレイ
                      _buildOverlays(paneConstraints),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data, {required this.barColor});
  final Uint8List data;
  final Color barColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    // 0と255のクリッピング除いた最大頻度値を探索して正規化
    int maxVal = 1;
    for (var i = 1; i < 255; i++) {
      if (data[i] > maxVal) maxVal = data[i];
    }

    final path = Path();
    final fillPath = Path()..moveTo(0, size.height);

    final step = size.width / 256.0;
    for (var i = 0; i < 256; i++) {
      final normalized = (data[i] / maxVal).clamp(0.0, 1.0);
      final x = i * step;
      final y = size.height - (normalized * (size.height - 2));
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    // 塗りつぶしグラデーション
    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          barColor.withValues(alpha: 0.55),
          barColor.withValues(alpha: 0.08),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fillPaint);

    // 輪郭線
    final strokePaint = Paint()
      ..color = barColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(path, strokePaint);

    // 白飛び警告（255が閾値超え）
    if (data[255] > maxVal * 0.7) {
      final warnPaint = Paint()..color = Colors.redAccent;
      canvas.drawCircle(Offset(size.width - 3, 3), 2.5, warnPaint);
    }
    // 黒つぶれ警告（0が閾値超え）
    if (data[0] > maxVal * 0.7) {
      final warnPaint = Paint()..color = Colors.blueAccent;
      canvas.drawCircle(const Offset(3, 3), 2.5, warnPaint);
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.data != data || old.barColor != barColor;
}

class FocusMaskCache {
  final int maxEntries;
  final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();

  FocusMaskCache({this.maxEntries = 50});

  bool containsKey(String key) => _cache.containsKey(key);

  Uint8List? operator [](String key) {
    if (!_cache.containsKey(key)) return null;
    final val = _cache.remove(key)!;
    _cache[key] = val; // Move to end (most recently used)
    return val;
  }

  void operator []=(String key, Uint8List value) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first); // Remove oldest
    }
    _cache[key] = value;
  }
}
