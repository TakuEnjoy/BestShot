import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/photo_entry.dart';
import '../services/analysis/focus_mask_service.dart';

class LoupeScreen extends StatefulWidget {
  const LoupeScreen({
    super.key,
    required this.items,
    required this.exifTexts,
    required this.scores,
  });

  final List<PhotoEntry> items;
  final List<String> exifTexts;
  final List<double> scores;

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
  Color _focusMaskColor = Colors.white;
  double _focusMaskOpacity = 0.8;

  bool _syncEnabled = false; // Changed: Default to false
  final List<TransformationController> _controllers = [];

  // For relative sync: track the start matrix when sync is enabled
  final List<Matrix4> _initialMatrices = [];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.items.length; i++) {
      _controllers.add(TransformationController());
    }
    _loadAll();
  }

  @override
  void dispose() {
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
        final b = _loadedBytes[key];
        if (b == null) {
          _focusMaskPngByKey[key] = null;
          continue;
        }
        final png = await compute(focusMaskPngFromBytes, b);
        if (!mounted) return;
        _focusMaskPngByKey[key] = png;
      }
    } finally {
      if (mounted) setState(() => _focusMaskBusy = false);
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ルーペモード'),
        actions: [
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

    final count = widget.items.length;
    if (count <= 3) {
      return Row(
        children: [
          for (int i = 0; i < count; i++) ...[
            if (i > 0) const VerticalDivider(width: 1),
            Expanded(
              child: _ZoomPane(
                bytes: _loadedBytes[widget.items[i].key]!,
                maskPng: _focusMaskPngByKey[widget.items[i].key],
                showFocusMask: _showFocusMask,
                maskColor: _focusMaskColor,
                maskOpacity: _focusMaskOpacity,
                title: 'Photo ${i + 1}',
                exif: widget.exifTexts[i],
                score: widget.scores[i],
                histogram: widget.items[i].histogram,
                controller: _controllers[i],
                onInteractionUpdate: () => _onInteractionUpdate(i),
              ),
            ),
          ],
        ],
      );
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
      exif: widget.exifTexts[index],
      score: widget.scores[index],
      histogram: widget.items[index].histogram,
      controller: _controllers[index],
      onInteractionUpdate: () => _onInteractionUpdate(index),
    );
  }
}

class _ZoomPane extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          color: Colors.black12,
          child: Text(title, style: Theme.of(context).textTheme.labelSmall),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: controller,
                  minScale: 1,
                  maxScale: 12,
                  onInteractionUpdate: (_) => onInteractionUpdate(),
                  child: Center(
                    child: Stack(
                      alignment: Alignment.center,
                      fit: StackFit.passthrough,
                      children: [
                        Image.memory(bytes, filterQuality: FilterQuality.high),
                        if (showFocusMask && maskPng != null)
                          Opacity(
                            opacity: maskOpacity,
                            child: Image.memory(
                              maskPng!,
                              filterQuality: FilterQuality.low,
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
                          if (exif.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Text(
                                exif,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          Text(
                            '鮮明度: ${score.toStringAsFixed(0)}',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 10,
                            ),
                          ),
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
                  child: CustomPaint(painter: _HistogramPainter(histogram)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.data);
  final Uint8List data;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;
    final barPaint = Paint()
      ..color = Colors.white.withOpacity(0.85)
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
  bool shouldRepaint(_HistogramPainter old) => old.data != data;
}
