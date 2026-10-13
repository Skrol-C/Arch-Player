import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'theme.dart';

/// The single glass authority. Every lens and bar in the app reads
/// from here - one recipe, or the floating unit falls apart.
///
/// Frosted, not pure: refractive lenses alone wash out over busy
/// artwork. Appearance lays a light frost + blur under the refraction;
/// adaptivity samples the backdrop and flips the tint light/dark by
/// itself (~300ms). Small elements use lite frost (tint + rim, no
/// refraction pass): cheaper on the Honor and more legible at 48px.
///
/// Escape hatch, stated in advance: if adaptivity sampling ever
/// janks, keep the frost and drop the sampling - legibility stays,
/// polish flexes.
abstract final class ArchGlass {
  static const _refraction =
      LiquidGlassRefraction(distortion: 0.08, distortionWidth: 10);

  static const frostAppearance = LiquidGlassAppearance(
    color: Color(0x4DFFFFFF),
    blur: LiquidGlassBlur(sigmaX: 8, sigmaY: 8),
  );

  static const adaptive = LiquidGlassAdaptivity(
    glassColorOnLight: Color(0x80FFFFFF),
    contentColorOnLight: ink,
    glassColorOnDark: Color(0x40000000),
    contentColorOnDark: Colors.white,
  );

  /// Capsules and bars (mini, back chip, sheets): refractive frost
  /// that adapts to the backdrop.
  static LiquidGlassStyle capsule({double radius = 34}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: radius, borderWidth: 1),
        appearance: frostAppearance,
        refraction: _refraction,
        adaptivity: adaptive,
      );

  /// Circles and small buttons (lobes, mini circles): lite frost,
  /// no refraction pass.
  static LiquidGlassStyle circle({double radius = 24}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: radius, borderWidth: 1),
        appearance: frostAppearance,
        liteGlass: LiquidGlassLitePickup.surface,
        adaptivity: adaptive,
      );

  /// Menus: glassier than the shared capsule - stronger rim bend,
  /// deeper frost, brighter tint. The menu shell never moves (static
  /// region, resolves once), so it can afford the heavier look.
  /// Fixed light, no adaptivity sampling: day-mode white always
  /// resolves light, and the ~300ms sampling flip read as flicker
  /// on every open.
  static LiquidGlassStyle menu({double radius = 28}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: radius, borderWidth: 1),
        appearance: const LiquidGlassAppearance(
          color: Color(0x66FFFFFF),
          blur: LiquidGlassBlur(sigmaX: 12, sigmaY: 12),
        ),
        refraction: const LiquidGlassRefraction(
            distortion: 0.13, distortionWidth: 14),
      );

  /// Sigma-ramped menu lens: identical recipe, blur animated 0-12
  /// across the entrance so consecutive frames differ
  /// infinitesimally (no blend step, nowhere for a flash to live).
  /// Refraction stays fixed - only blur moves, so the rim can't
  /// swim. Rebuilt per tick during the ramp only; static after.
  static LiquidGlassStyle menuWithSigma(double sigma) =>
      LiquidGlassStyle(
        shape: const LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: 28, borderWidth: 1),
        appearance: LiquidGlassAppearance(
          color: const Color(0x66FFFFFF),
          blur: LiquidGlassBlur(sigmaX: sigma, sigmaY: sigma),
        ),
        refraction: const LiquidGlassRefraction(
            distortion: 0.13, distortionWidth: 14),
      );

  /// Morphed menu lens: the lens starts life AS the travel cover
  /// (opaque paper-white, zero blur, zero bend) and becomes the
  /// recipe as [p] goes 0-1. The swap frame is pixel-identical on
  /// both sides, so no blend - and no flash - can exist. End
  /// state (p=1) is pixel-identical to menu().
  static LiquidGlassStyle menuMorphed(double p) {
    final s = (p * p * (3 - 2 * p)).clamp(0.0, 1.0);
    return LiquidGlassStyle(
      shape: const LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: 28, borderWidth: 1),
      appearance: LiquidGlassAppearance(
        color: Color.lerp(paper, const Color(0x66FFFFFF), s)!,
        blur: LiquidGlassBlur(sigmaX: 12 * s, sigmaY: 12 * s),
      ),
      refraction: LiquidGlassRefraction(
          distortion: 0.13 * s, distortionWidth: 14),
    );
  }
}
