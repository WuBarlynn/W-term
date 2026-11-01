import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Paints the selected skin behind the whole application. Built-in skins use
/// vector-only decoration; custom skins may provide a compressed bitmap.
class SkinBackdrop extends StatelessWidget {
  final Widget child;
  final String skinKey;
  final bool dark;
  final int top, bottom, seed;
  final double overlay;
  final Uint8List? image;
  const SkinBackdrop({
    super.key,
    required this.child,
    required this.skinKey,
    required this.dark,
    required this.top,
    required this.bottom,
    required this.seed,
    required this.overlay,
    this.image,
  });

  @override
  Widget build(BuildContext context) {
    final topColor = Color(top);
    final bottomColor = Color(bottom);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image != null)
          Image.memory(image!, fit: BoxFit.cover, gaplessPlayback: true)
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [topColor, bottomColor],
              ),
            ),
          ),
        if (image == null)
          IgnorePointer(
            child: CustomPaint(
              painter: _SkinPatternPainter(
                skinKey: skinKey,
                dark: dark,
                accent: Color(seed),
              ),
            ),
          ),
        IgnorePointer(
          child: ColoredBox(
            color: topColor.withValues(alpha: overlay.clamp(0.0, 0.6)),
          ),
        ),
        child,
      ],
    );
  }
}

class _SkinPatternPainter extends CustomPainter {
  final String skinKey;
  final bool dark;
  final Color accent;
  const _SkinPatternPainter({
    required this.skinKey,
    required this.dark,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = accent.withValues(alpha: dark ? 0.16 : 0.20);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(size.width, size.height) * 0.003
      ..color = accent.withValues(alpha: dark ? 0.22 : 0.28);
    switch (skinKey) {
      case 'emerald':
      case 'ink':
        for (var i = 0; i < 5; i++) {
          final radius = size.width * (0.18 + i * 0.12);
          canvas.drawCircle(
            Offset(size.width * (0.15 + i * 0.18), size.height * 0.78),
            radius,
            line,
          );
        }
        break;
      case 'sunset':
      case 'coast':
        for (var i = 0; i < 4; i++) {
          final y = size.height * (0.28 + i * 0.16);
          final path = Path()..moveTo(0, y);
          for (var x = 0.0; x <= size.width; x += size.width / 8) {
            path.lineTo(
              x,
              y + math.sin(x / size.width * math.pi * 2 + i) * 24,
            );
          }
          canvas.drawPath(path, line);
        }
        break;
      case 'starry':
      case 'aurora':
        final random = math.Random(17);
        for (var i = 0; i < 55; i++) {
          canvas.drawCircle(
            Offset(
              random.nextDouble() * size.width,
              random.nextDouble() * size.height,
            ),
            random.nextDouble() * 2.2 + 0.6,
            paint,
          );
        }
        break;
      case 'sakura':
        for (var i = 0; i < 18; i++) {
          final x = size.width * ((i * 37 % 100) / 100);
          final y = size.height * ((i * 61 % 100) / 100);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(x, y),
              width: 22,
              height: 10,
            ),
            paint,
          );
        }
        break;
      case 'neon':
        for (var i = 0; i < 4; i++) {
          final y = size.height * (0.25 + i * 0.18);
          final path = Path()
            ..moveTo(0, y)
            ..lineTo(size.width * 0.35, y - 18)
            ..lineTo(size.width * 0.62, y + 22)
            ..lineTo(size.width, y - 12);
          canvas.drawPath(path, line);
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SkinPatternPainter oldDelegate) =>
      oldDelegate.skinKey != skinKey || oldDelegate.accent != accent;
}
