import 'package:flutter/material.dart';
import '../theme/bestshot_theme.dart';

/// フラットなプロフェッショナル・サーフェスコンテナ
/// （旧GlassContainerのインターフェースを維持しつつ、ブラーやシャドウを排したフラット仕様）
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.margin,
    this.backgroundColor,
    this.borderColor,
    this.blur = 0.0,
    this.width,
    this.height,
    this.constraints,
  });

  final Widget child;
  final BorderRadiusGeometry? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? backgroundColor;
  final Color? borderColor;
  final double blur;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final defaultRadius = BorderRadius.circular(4);

    return Container(
      margin: margin,
      width: width,
      height: height,
      constraints: constraints,
      decoration: BoxDecoration(
        color: backgroundColor ?? BestShotTheme.surfaceColor,
        borderRadius: borderRadius ?? defaultRadius,
        border: Border.all(
          color: borderColor ?? BestShotTheme.dividerColor,
          width: 1.0,
        ),
      ),
      padding: padding,
      child: child,
    );
  }
}
