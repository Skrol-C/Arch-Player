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
  static const _refraction = LiquidGlassRefraction(
    distortion: 0.08,
    distortionWidth: 10,
  );

  /// AMOLED refraction: less bend — there is nothing to bend on #000,
  /// so a full-strength field just shimmers.
  static const _amoledRefraction = LiquidGlassRefraction(
    distortion: 0.06,
    distortionWidth: 10,
  );

  static const frostAppearance = LiquidGlassAppearance(
    color: Color(0x4DFFFFFF),
    blur: LiquidGlassBlur(sigmaX: 8, sigmaY: 8),
  );

  /// AMOLED frost: dark veil (~70% #1C1C1E) instead of white.
  /// White frost over #000 reads gray haze and burns pixels.
  static const amoledFrostAppearance = LiquidGlassAppearance(
    color: Color(0xB31C1C1E),
    blur: LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
  );

  static const _amoledSheetAppearance = LiquidGlassAppearance(
    color: Color(0xCC1C1C1E),
    blur: LiquidGlassBlur(sigmaX: 12, sigmaY: 12),
  );

  static const _amoledMenuAppearance = LiquidGlassAppearance(
    color: Color(0xCC1C1C1E),
    blur: LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
  );

  static const adaptive = LiquidGlassAdaptivity(
    glassColorOnLight: Color(0x80FFFFFF),
    contentColorOnLight: ink,
    glassColorOnDark: Color(0x40000000),
    contentColorOnDark: Colors.white,
  );

  /// AMOLED adaptivity: the dark verdict stays on the container tier
  /// so the lens parts from the #000 page instead of vanishing.
  static const amoledAdaptive = LiquidGlassAdaptivity(
    glassColorOnLight: Color(0x80FFFFFF),
    contentColorOnLight: ink,
    glassColorOnDark: Color(0xCC1C1C1E),
    contentColorOnDark: Colors.white,
  );

  /// Capsules and bars (mini, back chip, sheets): refractive frost
  /// that adapts to the backdrop. `amoled` swaps the white veil for
  /// the dark one and eases the bend.
  static LiquidGlassStyle capsule({double radius = 34, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1,
        ),
        appearance: amoled ? amoledFrostAppearance : frostAppearance,
        refraction: amoled ? _amoledRefraction : _refraction,
        adaptivity: amoled ? amoledAdaptive : adaptive,
      );

  /// Circles and small buttons (lobes, mini circles): lite frost,
  /// no refraction pass.
  static LiquidGlassStyle circle({double radius = 24, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1,
        ),
        appearance: amoled ? amoledFrostAppearance : frostAppearance,
        liteGlass: LiquidGlassLitePickup.surface,
        adaptivity: amoled ? amoledAdaptive : adaptive,
      );

  /// View-menu trigger (artists `...`): a 44 px button that must read
  /// as GLASS against the page, so the morph has something
  /// visible to melt out of. Refractive, not lite: Snell bend + radial
  /// specular + saturated rim pushed hard at small-surface scale —
  /// wide bevel band, bright tint, deep blur, solid-leaning rim — so
  /// the lens edge separates from paper even with nothing behind it
  /// to bend. `amoled` swaps the white veil for the dark one so the
  /// edge separates from #000 instead of hazing it.
  ///
  /// Rigid by design: no flex touch. The flex driver listens on a raw
  /// Listener that never joins the gesture arena, so inside a
  /// scrollable it deforms through scroll drags and fights the
  /// scroll. The tap lives on the outer GestureDetector instead.
  static LiquidGlassStyle trigger({double radius = 22, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 2.2,
          lightMode: LiquidGlassLightMode.radial,
          borderType: const OpticalBorder(
            borderSaturation: 2.6,
            ambientIntensity: 1.6,
            borderSolidity: 0.5,
            lightSpread: 1.0,
          ),
        ),
        appearance: amoled
            ? _amoledMenuAppearance
            : const LiquidGlassAppearance(
                color: Color(0xA6FFFFFF),
                blur: LiquidGlassBlur(sigmaX: 18, sigmaY: 18),
              ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                refractionType: OpticalRefraction(
                  refraction: 1.5,
                  refractionWidth: 20,
                  depth: 0.5,
                ),
              ),
      );

  /// Menus: glassier than the shared capsule - stronger rim bend,
  /// deeper frost, brighter tint. The menu shell never moves (static
  /// region, resolves once), so it can afford the heavier look.
  /// Fixed light, no adaptivity sampling: day-mode white always
  /// resolves light, and the ~300ms sampling flip read as flicker
  /// on every open. `amoled` swaps to the dark veil for true black.
  static LiquidGlassStyle menu({double radius = 28, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1,
        ),
        appearance: amoled ? _amoledMenuAppearance : const LiquidGlassAppearance(
          color: Color(0x66FFFFFF),
          blur: LiquidGlassBlur(sigmaX: 12, sigmaY: 12),
        ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                distortion: 0.13,
                distortionWidth: 14,
              ),
      );

  /// Menu V2: the optical recipe. PARKED alongside
  /// `showMorphMenu` in features/shell/morph_menu.dart - kept for the
  /// day the morph entrance comes back, not referenced anywhere.
  /// Snell's-law bend instead of the legacy distortion field, radial
  /// specular sweep, saturated optical rim. Built for a morph
  /// entrance: the band grows with the surface while it bulges out
  /// of its anchor, so refraction never swallows a small frame
  /// mid-animation.
  static LiquidGlassStyle menuV2({double radius = 28, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1.2,
          lightMode: LiquidGlassLightMode.radial,
          borderType:
              const OpticalBorder(borderSaturation: 1.6, lightSpread: 0.7),
        ),
        appearance: amoled
            ? _amoledMenuAppearance
            : const LiquidGlassAppearance(
                color: Color(0x66FFFFFF),
                blur: LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
              ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                refractionType: OpticalRefraction(
                  refraction: 1.5,
                  refractionWidth: 28,
                  depth: 0.24,
                ),
              ),
      );

  /// Sheets: SpotiFLAC-mornye grammar in our skin (MIT): white
  /// veil ~0.46, tight blur, strong rim bend. Frost reads dirty
  /// over busy art; the veil + bend carry readability instead.
  /// `amoled` swaps the white veil for the dark one.
  static LiquidGlassStyle sheet({double radius = 28, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1,
        ),
        appearance: amoled ? _amoledSheetAppearance : const LiquidGlassAppearance(
          color: Color(0x75FFFFFF),
          blur: LiquidGlassBlur(sigmaX: 3, sigmaY: 3),
        ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                distortion: 0.16,
                distortionWidth: 16,
              ),
      );

  /// Sigma-ramped menu lens: identical recipe, blur animated 0-12
  /// across the entrance so consecutive frames differ
  /// infinitesimally (no blend step, nowhere for a flash to live).
  /// Refraction stays fixed - only blur moves, so the rim can't
  /// swim. Rebuilt per tick during the ramp only; static after.
  static LiquidGlassStyle menuWithSigma(double sigma, {bool amoled = false}) =>
      LiquidGlassStyle(
        shape: const LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: 28,
          borderWidth: 1,
        ),
        appearance: LiquidGlassAppearance(
          color: amoled
              ? const Color(0xCC1C1C1E)
              : const Color(0x66FFFFFF),
          blur: LiquidGlassBlur(sigmaX: sigma, sigmaY: sigma),
        ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                distortion: 0.13,
                distortionWidth: 14,
              ),
      );

  /// Morphed menu lens: the lens renders the RESTED recipe from
  /// frame zero - no paper cover, no morph. The cover existed to
  /// prevent a theoretical swap flash; on real hardware the
  /// cover's own first frame was the visible artifact (white
  /// border parked while blur compiled). If a swap flash ever
  /// shows, it reproduces in one tap and reverts in one line.
  static LiquidGlassStyle menuMorphed(double p, {bool amoled = false}) {
    return LiquidGlassStyle(
      shape: const LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: 28,
        borderWidth: 1,
      ),
      appearance: LiquidGlassAppearance(
        color: amoled ? const Color(0xCC1C1C1E) : const Color(0x66FFFFFF),
        blur: const LiquidGlassBlur(sigmaX: 12, sigmaY: 12),
      ),
      refraction: amoled
          ? _amoledRefraction
          : const LiquidGlassRefraction(distortion: 0.13, distortionWidth: 14),
    );
  }

  /// Morph entrance: the destination recipe for native
  /// LiquidGlassMorph (features/shell/morph_menu.dart). Same optical
  /// family as menuV2 - Snell bend, radial specular sweep, saturated
  /// rim - but owned by the live entrance, not the parked experiment.
  /// The morph thickens blur/refraction itself while the glass grows,
  /// so this authors the rested state only.
  static LiquidGlassStyle menuMorph({double radius = 28, bool amoled = false}) =>
      LiquidGlassStyle(
        shape: LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: radius,
          borderWidth: 1.2,
          lightMode: LiquidGlassLightMode.radial,
          borderType:
              const OpticalBorder(borderSaturation: 1.6, lightSpread: 0.7),
        ),
        appearance: amoled
            ? _amoledMenuAppearance
            : const LiquidGlassAppearance(
                color: Color(0x66FFFFFF),
                blur: LiquidGlassBlur(sigmaX: 14, sigmaY: 14),
              ),
        refraction: amoled
            ? _amoledRefraction
            : const LiquidGlassRefraction(
                refractionType: OpticalRefraction(
                  refraction: 1.5,
                  refractionWidth: 28,
                  depth: 0.24,
                ),
              ),
      );

  /// House touch: every tappable lens answers the finger the same way.
  /// Subtle by house rule (premium = restraint) - press compresses,
  /// release wobbles back. Rigid everywhere else: null means no
  /// gesture listener, no ticker, nothing added to the tree.
  static LiquidGlassTouch lensTouch() =>
      const LiquidGlassTouch.flexing(LiquidGlassFlex.subtle());
}
