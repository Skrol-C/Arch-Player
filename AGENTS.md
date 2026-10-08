# Arch Player — Flutter + liquid_glass_easy

Android-only, sideload APK. Most visual player on Android.

## Stack
- Flutter 3.47 (stable) + `liquid_glass_easy` (Impeller refractive lenses)
- Same package: `com.archstudios.arch_player`
- Engine later: just_audio + audio_service + own MediaStore scan (proven packages)

## Toolchain (Windows)
- Flutter: `C:/Users/banan/flutter/bin/flutter.bat` (not on PATH — full path)
- `JAVA_HOME="C:/Program Files/Android/Android Studio/jbr"`
- `ANDROID_HOME="C:/Users/banan/AppData/Local/Android/Sdk"`
- Phone over Wi-Fi ADB (`installDebug` equivalent: `flutter run` / `flutter install`)

## Look
- Apple Music-grade premium, Arch red (#FA1744) on near-black. Red = accents only.
- Nav: liquid-glass pill (Home/Library/Settings; Needle = future downloads).
- Glass rules: lens refracts backdrop + icons, bend the bevel only, middle stays
  clear, shimmer on reveal only. SpotiFLAC's MornyeSelectionPill is the reference.

## Rules
1. No dead screens. Everything moves. Zero-motion = bug.
2. Touch everything. Physical looks = physical acts.
3. Glass only on floating nav. Never in content, never stacked.
4. Feature slices from day one (`lib/features/`, `lib/core/`). No logic in main.
5. Prove on device: Wi-Fi install to phone, tap it, no cable needed.

## Build
- Analyze: `flutter analyze` (full flutter path above)
- Run: `flutter run --debug` / install: `flutter install`
