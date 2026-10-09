import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';
import '../../core/theme.dart';

/// The anti-swamp screen: everything the app logged, readable and
/// shareable. Stolen with respect from SpotiFLAC's log screen.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  Future<String>? _content;

  @override
  void initState() {
    super.initState();
    _content = _read();
  }

  Future<String> _read() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/arch.log');
      if (!await file.exists()) return 'No log entries yet.';
      final lines = await file.readAsLines();
      return lines.reversed.take(400).join('\n');
    } catch (e) {
      return 'Could not read the log: $e';
    }
  }

  Future<void> _share() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final params = ShareParams(
        files: [XFile('${dir.path}/arch.log')],
        subject: 'Arch Player log',
      );
      await SharePlus.instance.share(params);
    } catch (e) {
      ArchLog.w('logscreen', 'share failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'log screen open');
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log'),
        actions: [
          IconButton(onPressed: _share, icon: const Icon(Icons.share_rounded)),
        ],
      ),
      body: FutureBuilder<String>(
        future: _content,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator(color: archPink));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              snap.data!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.5),
            ),
          );
        },
      ),
    );
  }
}
