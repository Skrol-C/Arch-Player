import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Audio container family, derived from the file extension we already
/// carry. M4A stays neutral (AAC or ALAC inside - never guessed).
enum AudioFormat { flac, wav, alac, mp3, aac, ogg, opus, m4a, unknown }

AudioFormat formatOf(String path) {
  if (!path.contains('.')) return AudioFormat.unknown;
  switch (path.split('.').last.toLowerCase()) {
    case 'flac':
      return AudioFormat.flac;
    case 'wav':
      return AudioFormat.wav;
    case 'alac':
      return AudioFormat.alac;
    case 'mp3':
      return AudioFormat.mp3;
    case 'aac':
      return AudioFormat.aac;
    case 'ogg':
    case 'oga':
      return AudioFormat.ogg;
    case 'opus':
      return AudioFormat.opus;
    case 'm4a':
      return AudioFormat.m4a;
    default:
      return AudioFormat.unknown;
  }
}

bool formatLossless(AudioFormat f) =>
    f == AudioFormat.flac || f == AudioFormat.wav || f == AudioFormat.alac;

bool formatLossy(AudioFormat f) =>
    f == AudioFormat.mp3 ||
    f == AudioFormat.aac ||
    f == AudioFormat.ogg ||
    f == AudioFormat.opus;

String formatLabel(AudioFormat f) => switch (f) {
  AudioFormat.flac => 'FLAC',
  AudioFormat.wav => 'WAV',
  AudioFormat.alac => 'ALAC',
  AudioFormat.mp3 => 'MP3',
  AudioFormat.aac => 'AAC',
  AudioFormat.ogg => 'OGG',
  AudioFormat.opus => 'OPUS',
  AudioFormat.m4a => 'M4A',
  AudioFormat.unknown => '',
};

/// Format chip: sourced logo file first (mp3/m4a/flac/aac plus
/// official Opus and Vorbis marks, see docs/ASSET-NOTICES.md), our
/// geometric mark otherwise, text label alongside either way.
/// Unknown extensions render nothing — never a placeholder glyph.
class FormatChip extends StatelessWidget {
  final String path;
  final bool dark;

  const FormatChip({super.key, required this.path, this.dark = false});

  static String? _assetFor(AudioFormat format) => switch (format) {
    AudioFormat.mp3 => 'assets/logos/mp3.png',
    AudioFormat.m4a => 'assets/logos/m4a/m4a.png',
    AudioFormat.flac => 'assets/logos/flac/flac.png',
    AudioFormat.aac => 'assets/logos/aac/aac.png',
    AudioFormat.opus => 'assets/logos/opus/opus.png',
    AudioFormat.ogg => 'assets/logos/ogg/vorbis.png',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final format = formatOf(path);
    if (format == AudioFormat.unknown) return const SizedBox.shrink();
    final base = dark ? moon : ink;
    final lossless = formatLossless(format);
    final asset = _assetFor(format);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (asset != null)
          Image.asset(
            asset,
            width: 22,
            height: 22,
            errorBuilder: (_, _, _) => SizedBox(
              width: 18,
              height: 18,
              child: CustomPaint(
                painter: _FormatGlyph(
                  format: format,
                  color: base,
                  lossless: lossless,
                ),
              ),
            ),
          )
        else
          CustomPaint(
            size: const Size(18, 18),
            painter: _FormatGlyph(
              format: format,
              color: base,
              lossless: lossless,
            ),
          ),
        const SizedBox(width: 6),
        Text(
          formatLabel(format),
          style: TextStyle(
            color: base,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (lossless)
          const Text(
            ' - LOSSLESS',
            style: TextStyle(
              color: archPink,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }
}

class _FormatGlyph extends CustomPainter {
  final AudioFormat format;
  final Color color;
  final bool lossless;

  _FormatGlyph({
    required this.format,
    required this.color,
    required this.lossless,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final fill = Paint()
      ..color = color
      ..style = lossless ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    final cx = w / 2, cy = h / 2;
    switch (format) {
      case AudioFormat.flac:
        // Layered bars.
        for (var i = 0; i < 3; i++) {
          final bw = w * (0.9 - i * 0.22);
          canvas.drawRRect(
            RRect.fromLTRBR(
              cx - bw / 2,
              3.0 + i * 5.0,
              cx + bw / 2,
              6.4 + i * 5.0,
              const Radius.circular(1),
            ),
            fill,
          );
        }
      case AudioFormat.wav:
        // Waveform with a center swell.
        final wave = Path();
        for (var x = 1.0; x <= w - 1; x += 1.0) {
          final u = x / w;
          final y =
              cy +
              (h / 2 - 2) * math.sin(u * math.pi * 2) * math.sin(u * math.pi);
          if (x == 1.0) {
            wave.moveTo(x, y);
          } else {
            wave.lineTo(x, y);
          }
        }
        canvas.drawPath(wave, fill..style = PaintingStyle.stroke);
      case AudioFormat.alac:
        // Diamond.
        canvas.drawPath(
          Path()
            ..moveTo(cx, 1.5)
            ..lineTo(w - 1.5, cy)
            ..lineTo(cx, h - 1.5)
            ..lineTo(1.5, cy)
            ..close(),
          fill,
        );
      case AudioFormat.mp3:
        // Three ticks.
        for (var i = 0; i < 3; i++) {
          final x = 4.0 + i * 5.0;
          canvas.drawLine(Offset(x, h - 3), Offset(x, 3 + i * 1.5), fill);
        }
      case AudioFormat.aac:
        // Two arcs.
        canvas.drawArc(
          Rect.fromLTWH(2, 2, w - 4, h - 4),
          3.14 * 1.1,
          3.14 * 0.8,
          false,
          fill..style = PaintingStyle.stroke,
        );
        canvas.drawArc(
          Rect.fromLTWH(5, 5, w - 10, h - 10),
          3.14 * 1.1,
          3.14 * 0.8,
          false,
          fill..style = PaintingStyle.stroke,
        );
      case AudioFormat.ogg:
        // Orbit: ellipse + dot.
        canvas.drawOval(Rect.fromLTWH(1.5, 4.5, w - 3, h - 9), fill);
        canvas.drawCircle(
          Offset(cx + 3, cy - 2),
          1.6,
          fill..style = PaintingStyle.fill,
        );
      case AudioFormat.opus:
        // Concentric arcs.
        for (var i = 0; i < 2; i++) {
          final inset = 2.0 + i * 4.0;
          canvas.drawArc(
            Rect.fromLTWH(inset, inset, w - inset * 2, h - inset * 2),
            -1.2,
            2.4,
            false,
            fill..style = PaintingStyle.stroke,
          );
        }
      case AudioFormat.m4a:
        // Rounded square.
        canvas.drawRRect(
          RRect.fromLTRBR(2.5, 2.5, w - 2.5, h - 2.5, const Radius.circular(5)),
          fill,
        );
      case AudioFormat.unknown:
        break;
    }
  }

  @override
  bool shouldRepaint(_FormatGlyph old) =>
      old.format != format || old.color != color || old.lossless != lossless;
}
