import 'dart:ui';
import 'package:flutter/material.dart';

class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius,
    this.padding,
    this.margin,
    this.backgroundColor,
    this.borderColor,
    this.blur = 24.0,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final defaultRadius = BorderRadius.circular(24);
    
    return Container(
      margin: margin,
      width: width,
      height: height,
      constraints: constraints,
      child: ClipRRect(
        borderRadius: borderRadius ?? defaultRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: backgroundColor ?? colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
              borderRadius: borderRadius ?? defaultRadius,
              border: Border.all(
                color: borderColor ?? colorScheme.outlineVariant.withValues(alpha: 0.25),
                width: 1.2,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
