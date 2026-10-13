import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Needle teaser: name, promise, no dead end. Engine lands per vision 8.
class NeedleTeaser extends StatelessWidget {
  const NeedleTeaser({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Needle')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: [
          FocalEntrance(
            child: Text('Needle', style: Theme.of(context).textTheme.headlineLarge),
          ),
          const SizedBox(height: 8),
          const Text(
            'Music, gotten inside the app. Sources plug in as providers - no second app needed.',
            style: TextStyle(color: inkDim, height: 1.5),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: paperRaised,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How it will work',
                    style: TextStyle(color: archPink, fontWeight: FontWeight.w700)),
                SizedBox(height: 8),
                Text(
                  'Search a source, pick quality up to lossless, queue it, '
                  'and find it tagged in your library. One built-in provider '
                  'proves the system; the community adds the rest.',
                  style: TextStyle(color: inkDim, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
