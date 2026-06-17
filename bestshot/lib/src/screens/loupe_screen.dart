import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/photo_entry.dart';
import '../services/analysis/focus_mask_service.dart';

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

  // Cache focus mask bytes for the duration of the app session
  static final Map<String, Uint8List> _sessionMaskCache = {};

  @override
  State<LoupeScreen> createState() => _LoupeScreenState();
}

class _LoupeScreenState extends State<LoupeScreen> {
  bool _loading = true;
  Object? _error;
  final Map<String, Uint8List> _loadedBytes = {};

  bool _showFocusMask = false;
  bool _focusMaskBusy = false;
  final Map<String, Uint8List?> _focusMaskPngByKey = {};
  Color _focusMaskColor = Colors.white; // Non-final to allow color cycle
  double _focusMaskOpacity = 0.8;

  // Keyboard focus management
  late final FocusNode _focusNode;
  int _activePaneIndex = 0;
  bool _showDebugOverlay = false;

  bool _syncEnabled = false; // Changed: Default to false
  final List<TransformationController> _controllers = [];

  // For relative sync: track the start matrix when sync is enabled
  final List<Matrix4> _initialMatrices = [];

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    for (var i = 0; i < widget.items.length; i++) {
      _controllers.add(TransformationController());
    }
    _loadAll();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
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

    final currentMatrix = _controllers[sourceIndex].value;
    final startMatrix = _initialMatrices[sourceIndex];

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
      for (final item in widget.items) {
        final bytes = await _loadFull(item);
        if (bytes != null) {
          _loadedBytes[item.key] = bytes;
        }
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
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
    Colors.white,
    Colors.red,
    Colors.yellow,
    Colors.green,
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

    if (key == LogicalKeyboardKey.space) {
      if (_activePaneIndex >= 0 && _activePaneIndex < count) {
        final itemKey = widget.items[_activePaneIndex].key;
        final currentlySelected = widget.initialSelectedForDelete?.contains(itemKey) ?? false;
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
          for (var i = 0; i < widget.isBests.length; i++) {
            widget.isBests[i] = (widget.items[i].key == itemKey);
          }
        });
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handleKeyEvent(event),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ルーペモード'),
          actions: [
            IconButton(
              tooltip: 'デバッグ表示を切り替え',
              onPressed: () => setState(() => _showDebugOverlay = !_showDebugOverlay),
              icon: Icon(
                _showDebugOverlay ? Icons.bug_report : Icons.bug_report_outlined,
                color: _showDebugOverlay ? Colors.redAccent : null,
              ),
            ),
            IconButton(
              tooltip: _showFocusMask ? 'フォーカスマスクを隠す' : 'フォーカスマスクを表示',
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
              const SizedBox(width: 8),
              SizedBox(
                width: 100,
                child: Slider(
                  value: _focusMaskOpacity,
                  onChanged: (v) => setState(() => _focusMaskOpacity = v),
                ),
              ),
            ],
            Row(
              children: [
                const Text('連動拡大'),
                Switch(
                  value: _syncEnabled,
                  onChanged: (v) {
                    setState(() {
                      _syncEnabled = v;
                      if (_syncEnabled) {
                        // Snapshot current positions as initial
                        _initialMatrices.clear();
                        for (final c in _controllers) {
                          _initialMatrices.add(c.value.clone());
                        }
                      }
                    });
                  },
                ),
              ],
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: _buildBody(),
        bottomNavigationBar: _buildBottomBar(),
      ),
    );
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
            for (int i = 0; i < count; i++) ...[
              if (i > 0) const Divider(height: 1),
              Expanded(
                child: _buildPane(i),
              ),
            ],
          ],
        );
      } else {
        return Row(
          children: [
            for (int i = 0; i < count; i++) ...[
              if (i > 0) const VerticalDivider(width: 1),
              Expanded(
                child: _buildPane(i),
              ),
            ],
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
                const VerticalDivider(width: 1),
                Expanded(child: _buildPane(1)),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildPane(2)),
                const VerticalDivider(width: 1),
                Expanded(child: _buildPane(3)),
              ],
            ),
          ),
        ],
      );
    }
  }

  Widget _buildBottomBar() {
    if (_loading || _error != null || widget.items.isEmpty) return const SizedBox.shrink();
    if (_activePaneIndex < 0 || _activePaneIndex >= widget.items.length) return const SizedBox.shrink();

    final item = widget.items[_activePaneIndex];
    final key = item.key;
    final isBest = widget.isBests[_activePaneIndex];
    final selectedForDelete = widget.initialSelectedForDelete?.contains(key) ?? false;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF111827).withOpacity(0.92), // Deep Dark Card
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF1F2937), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Active photo indicator info
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '選択中: Photo ${_activePaneIndex + 1}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'ピント値: ${widget.scores[_activePaneIndex].toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.6),
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
              borderRadius: BorderRadius.circular(10),
              child: Container(
                constraints: const BoxConstraints(minWidth: 100),
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: selectedForDelete ? Colors.red.withOpacity(0.15) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selectedForDelete ? Colors.red : Colors.white30,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      selectedForDelete ? Icons.delete_forever : Icons.delete_outline,
                      color: selectedForDelete ? Colors.red : Colors.white70,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '削除候補',
                      style: TextStyle(
                        color: selectedForDelete ? Colors.redAccent : Colors.white70,
                        fontSize: 12,
                        fontWeight: selectedForDelete ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),

            // Toggle Best button
            InkWell(
              onTap: () {
                widget.onSetBest?.call(key);
                setState(() {
                  for (var j = 0; j < widget.isBests.length; j++) {
                    widget.isBests[j] = (j == _activePaneIndex);
                  }
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                constraints: const BoxConstraints(minWidth: 100),
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: isBest ? Colors.amber.withOpacity(0.15) : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isBest ? Colors.amber : Colors.white30,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isBest ? Icons.star : Icons.star_border,
                      color: isBest ? Colors.amber : Colors.white70,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isBest ? 'Best' : 'Bestに設定',
                      style: TextStyle(
                        color: isBest ? Colors.amber : Colors.white70,
                        fontSize: 12,
                        fontWeight: isBest ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPane(int index) {
    if (index >= widget.items.length) return const SizedBox.shrink();
    final key = widget.items[index].key;
    return _ZoomPane(
      bytes: _loadedBytes[key]!,
      maskPng: _focusMaskPngByKey[key],
      showFocusMask: _showFocusMask,
      maskColor: _focusMaskColor,
      maskOpacity: _focusMaskOpacity,
      title: 'Photo ${index + 1}',
      exif: widget.items[index].exifText,
      score: widget.scores[index],
      histogram: widget.items[index].histogram,
      controller: _controllers[index],
      onInteractionUpdate: () => _onInteractionUpdate(index),
      itemKey: key,
      isFocused: index == _activePaneIndex,
      onTap: () {
        setState(() {
          _activePaneIndex = index;
        });
      },
      showDebugOverlay: _showDebugOverlay,
      debugGridSharps: widget.items[index].debugGridSharps,
      semanticObjects: widget.items[index].semanticObjects,
      faceX: widget.items[index].portraitFaceX,
      faceY: widget.items[index].portraitFaceY,
      faceW: widget.items[index].portraitFaceW,
      faceH: widget.items[index].portraitFaceH,
      faceScore: widget.items[index].faceQualityScore,
      exposureScore: widget.items[index].exposureScore,
    );
  }
}

class _ZoomPane extends StatefulWidget {
  const _ZoomPane({
    required this.bytes,
    required this.maskPng,
    required this.showFocusMask,
    required this.maskColor,
    required this.maskOpacity,
    required this.title,
    required this.exif,
    required this.score,
    required this.histogram,
    required this.controller,
    required this.onInteractionUpdate,
    required this.itemKey,
    required this.isFocused,
    required this.onTap,
    required this.showDebugOverlay,
    this.debugGridSharps,
    this.semanticObjects,
    this.faceX,
    this.faceY,
    this.faceW,
    this.faceH,
    this.faceScore,
    this.exposureScore,
  });

  final Uint8List bytes;
  final Uint8List? maskPng;
  final bool showFocusMask;
  final Color maskColor;
  final double maskOpacity;
  final String title;
  final String exif;
  final double score;
  final Uint8List histogram;
  final TransformationController controller;
  final VoidCallback onInteractionUpdate;
  final String itemKey;
  final bool isFocused;
  final VoidCallback onTap;

  final bool showDebugOverlay;
  final List<double>? debugGridSharps;
  final List<SemanticObject>? semanticObjects;
  final int? faceX;
  final int? faceY;
  final int? faceW;
  final int? faceH;
  final double? faceScore;
  final double? exposureScore;

  @override
  State<_ZoomPane> createState() => _ZoomPaneState();
}

class _ZoomPaneState extends State<_ZoomPane> {
  int? _imageWidth;
  int? _imageHeight;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

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

  @override
  void dispose() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    super.dispose();
  }

  void _resolveImageSize() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    final provider = MemoryImage(widget.bytes);
    _imageStream = provider.resolve(ImageConfiguration.empty);
    _imageListener = ImageStreamListener((ImageInfo info, bool _) {
      if (mounted) {
        setState(() {
          _imageWidth = info.image.width;
          _imageHeight = info.image.height;
        });
      }
    });
    _imageStream!.addListener(_imageListener!);
  }

  List<Widget> _buildGridOverlay(double w, double h) {
    final sharps = widget.debugGridSharps!;
    if (sharps.length != 16) return [];

    final indexValues = List.generate(16, (i) => MapEntry(i, sharps[i]));
    indexValues.sort((a, b) => b.value.compareTo(a.value));
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
                  color: isTop4 ? Colors.green.withOpacity(0.6) : Colors.white24,
                  width: isTop4 ? 2.0 : 0.8,
                ),
                color: isTop4 ? Colors.green.withOpacity(0.08) : Colors.transparent,
              ),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
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
    final list = widget.semanticObjects!;
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
            border: Border.all(
              color: Colors.cyanAccent,
              width: 2.0,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: -16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  color: Colors.cyanAccent.withOpacity(0.85),
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
    final fx = widget.faceX! / imgW * w;
    final fy = widget.faceY! / imgH * h;
    final fw = widget.faceW! / imgW * w;
    final fh = widget.faceH! / imgH * h;

    return Positioned(
      left: fx,
      top: fy,
      width: fw,
      height: fh,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: Colors.orangeAccent,
            width: 2.0,
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: -16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: Colors.orangeAccent.withOpacity(0.85),
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.isFocused ? colorScheme.primary : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: widget.isFocused ? colorScheme.primaryContainer : Colors.black12,
              child: Text(
                widget.title,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: widget.isFocused ? colorScheme.onPrimaryContainer : null,
                  fontWeight: widget.isFocused ? FontWeight.bold : null,
                ),
              ),
            ),
            Expanded(
              child: Stack(
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
                            Image.memory(widget.bytes, filterQuality: FilterQuality.high),
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
                            if (widget.showDebugOverlay)
                              Positioned.fill(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final w = constraints.maxWidth;
                                    final h = constraints.maxHeight;
                                    if (w == 0 || h == 0) return const SizedBox.shrink();
                                    return Stack(
                                      children: [
                                        if (widget.debugGridSharps != null && widget.debugGridSharps!.length == 16)
                                          ..._buildGridOverlay(w, h),
                                        if (widget.semanticObjects != null)
                                          ..._buildObjectsOverlay(w, h),
                                        if (widget.faceX != null &&
                                            widget.faceY != null &&
                                            widget.faceW != null &&
                                            widget.faceH != null &&
                                            widget.faceW! > 0 &&
                                            widget.faceH! > 0 &&
                                            _imageWidth != null &&
                                            _imageHeight != null)
                                          _buildFaceOverlay(w, h),
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
                  // Overlay Info (Top Left)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.exif.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 2),
                                  child: Text(
                                    widget.exif,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              Text(
                                '鮮明度: ${widget.score.toStringAsFixed(0)}',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 10,
                                ),
                              ),
                              if (widget.showDebugOverlay) ...[
                                const SizedBox(height: 6),
                                Container(
                                  height: 1,
                                  width: 120,
                                  color: Colors.white24,
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  '【Debug Info】',
                                  style: TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  'ピント: ${widget.score.toStringAsFixed(1)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                                ),
                                Text(
                                  '露出: ${(widget.exposureScore ?? 0).toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                                ),
                                Text(
                                  '顔スコア: ${(widget.faceScore ?? 0).toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                                ),
                                Text(
                                  '解像度: ${_imageWidth ?? "?"} x ${_imageHeight ?? "?"}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 9),
                                ),
                                if (widget.semanticObjects != null && widget.semanticObjects!.isNotEmpty)
                                  Text(
                                    '検出数: ${widget.semanticObjects!.length} (例: ${widget.semanticObjects!.first.label})',
                                    style: const TextStyle(color: Colors.white70, fontSize: 9),
                                  ),
                              ]
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Histogram (Top Right)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: Container(
                      width: 100,
                      height: 60,
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: CustomPaint(
                        painter: _HistogramPainter(
                          widget.histogram,
                          barColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),

                ],
              ),
            ),
          ],
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
    
    final rect = Offset.zero & size;
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        barColor.withOpacity(0.85),
        barColor.withOpacity(0.2),
      ],
    );
    final barPaint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.fill
      ..isAntiAlias = false;

    // 256 bins => draw as bars; keep at least 1px wide bars.
    final binW = size.width / 256.0;
    final w = binW < 1 ? 1.0 : binW;
    for (var i = 0; i < 256; i++) {
      final h = (data[i] / 255) * size.height;
      if (h <= 0) continue;
      final x = i * binW;
      final rect = Rect.fromLTWH(x, size.height - h, w, h);
      canvas.drawRect(rect, barPaint);
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => old.data != data || old.barColor != barColor;
}
