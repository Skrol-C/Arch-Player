import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Compile glass shaders before the first frame: first glass is glass,
  // never first-frame frost.
  await LiquidGlassShaders.ensureLoaded();
  runApp(const ArchApp());
}

const archRed = Color(0xFFFA1744);
const ink = Color(0xFF0B0B0D);

class ArchApp extends StatelessWidget {
  const ArchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arch Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: ink,
        colorScheme: const ColorScheme.dark(
          primary: archRed,
          surface: ink,
        ),
      ),
      home: const GlassTrial(),
    );
  }
}

/// Milestone 1: green screen proving the glass pill travels like the real
/// thing. Backdrop gives the lens something to bend; the tab bar owns the
/// morph selection pill. Engine comes after the glass passes trial.
class GlassTrial extends StatefulWidget {
  const GlassTrial({super.key});

  @override
  State<GlassTrial> createState() => _GlassTrialState();
}

class _GlassTrialState extends State<GlassTrial> {
  int _index = 1; // Library first.

  static const _labels = ['Home', 'Library', 'Settings'];
  static const _icons = [Icons.home_rounded, Icons.library_music_rounded, Icons.settings_rounded];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Stand-in content: moody art-like backdrop with rows to bend.
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.6, -0.5),
                radius: 1.2,
                colors: [Color(0xFF3A0D18), ink],
              ),
            ),
          ),
          ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 64, 16, 160),
            itemCount: 24,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: LinearGradient(
                        colors: [
                          Color.lerp(archRed, Colors.purple, i / 24)!,
                          const Color(0xFF1C1C1F),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 14, width: 140.0 + (i % 5) * 22, color: Colors.white24),
                        const SizedBox(height: 6),
                        Container(height: 11, width: 90.0 + (i % 3) * 18, color: Colors.white12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 40,
            left: 16,
            child: Text(
              _labels[_index],
              style: Theme.of(context).textTheme.headlineLarge,
            ),
          ),
          // The glass pill. Real refractive lens, traveling morph selection.
          // withImpeller fills as the last Stack child and seats the bar
          // itself — never wrap it in Positioned.
          LiquidGlassTabBar.withImpeller(
            items: [
              for (var i = 0; i < _labels.length; i++)
                LiquidGlassTabBarItem(icon: _icons[i], label: _labels[i]),
            ],
            selectedIndex: _index,
            onChanged: (i) => setState(() => _index = i),
            width: 340,
            margin: const EdgeInsets.only(bottom: 40),
            itemStyle: const LiquidGlassTabItemStyle(
              selectedColor: archRed,
              unselectedColor: Color(0xD9FFFFFF),
              iconSize: 24,
              underGlassIconSize: 30,
              labelFontSize: 11,
            ),
            pillStyle: const LiquidGlassTabPillStyle(
              animated: true,
            ),
            style: LiquidGlassTabBar.defaultStyle.copyWith(
              appearance: const LiquidGlassAppearance(
                color: Color(0x14FFFFFF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
