import 'package:flutter/material.dart';

/// 高速・軽量な画面遷移用のカスタムPageRoute
/// 遷移時間を200ms（逆遷移150ms）に短縮し、FadeTransitionのみで描画負荷を最小化する
class FastRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;

  FastRoute({
    required this.builder,
    super.settings,
  }) : super(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              ),
              child: child,
            );
          },
        );
}
