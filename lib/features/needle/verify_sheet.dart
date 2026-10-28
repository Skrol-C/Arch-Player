import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/log.dart';
import '../../core/theme.dart';
import 'extensions.dart';
import 'session_grant.dart';

/// Provider verification challenge (signed-session grants).
/// Lazy by design: nothing here appears until a download actually
/// needs it. One active verify at a time; the held download
/// retries on grant, never fails.
class VerifyRequest {
  final String extId;
  final String displayName;
  final String authUrl;
  const VerifyRequest({
    required this.extId,
    required this.displayName,
    required this.authUrl,
  });
}

/// Opens the verify sheet. Returns true when a grant was captured
/// (caller retries the held pull), false on cancel/failure.
Future<bool> showVerifySheet(
  BuildContext context,
  VerifyRequest request,
) async {
  HapticFeedback.mediumImpact();
  final out = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _VerifySheet(request: request),
  );
  return out == true;
}

class _VerifySheet extends StatefulWidget {
  final VerifyRequest request;
  const _VerifySheet({required this.request});

  @override
  State<_VerifySheet> createState() => _VerifySheetState();
}

class _VerifySheetState extends State<_VerifySheet>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            ArchLog.w('needle', 'verify webview error: ${e.description}');
          },
          onNavigationRequest: (req) {
            final parsed =
                SessionGrant.parseGrantLink(req.url);
            if (parsed != null) {
              _complete(parsed['grant']!);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.request.authUrl));
    // System-browser return path: a grant may already wait.
    _checkPending();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_done) _checkPending();
  }

  Future<void> _checkPending() async {
    final link = await SessionGrant.takePendingLink();
    if (link == null || !mounted || _done) return;
    final parsed = SessionGrant.parseGrantLink(link);
    if (parsed != null) _complete(parsed['grant']!);
  }

  Future<void> _complete(String grant) async {
    if (_done) return;
    _done = true;
    final ok =
        await SessionGrant.stashGrant(widget.request.extId, grant);
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Could not save the grant. Try again.');
      _done = false;
      return;
    }
    HapticFeedback.mediumImpact();
    ArchLog.i('needle', 'grant captured for ${widget.request.extId}');
    Navigator.of(context).pop(true);
  }

  Future<void> _openExternal() async {
    HapticFeedback.selectionClick();
    final ok =
        await SessionGrant.openBrowser(widget.request.authUrl);
    if (!ok && mounted) {
      setState(() => _error = 'No browser found. Copy the link '
          'from Settings > Log.');
      ArchLog.w('needle', 'no browser for verify: ${widget.request.authUrl}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.82;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.verified_user_rounded,
                    color: archPink,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.request.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        'A quick check in the browser, once per install.',
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: Icon(Icons.close_rounded,
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text(
                _error!,
                style: const TextStyle(color: archPink, fontSize: 13),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Stack(
                  children: [
                    WebViewWidget(controller: _controller),
                    if (_loading)
                      const Center(
                        child: CircularProgressIndicator(color: archPink),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _openExternal,
                    child: const Text('Open in browser instead'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _checkPending,
                  child: const Text('I did it — check'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Resolve a display name for an extension id (falls back to id).
String displayNameFor(List<dynamic> providers, String extId) {
  for (final p in providers) {
    try {
      if ((p as dynamic).id == extId) {
        return ((p as dynamic).displayName as String?) ?? extId;
      }
    } catch (_) {}
  }
  return extId;
}

/// Trigger a verify sheet from a `verify-required` pull failure.
/// Returns true when granted (caller retries), false otherwise.
Future<bool> handleVerifyRequired(
  BuildContext context, {
  required String extId,
  required String displayName,
  required String authUrl,
}) {
  return showVerifySheet(
    context,
    VerifyRequest(
        extId: extId, displayName: displayName, authUrl: authUrl),
  );
}

/// Complete a grant via the extension entry when present (backup
/// path; the Rust driver auto-exchanges stashed grants anyway).
Future<void> completeGrantEntry(String extId) async {
  try {
    final h = await loadExtension(extId);
    final fns = await extensionFunctions(h.handle);
    if (!fns.contains('completeGrant')) return;
    await callExtensionFn(h.handle, 'completeGrant', [],
        timeoutMs: 30000);
  } catch (e) {
    ArchLog.w('needle', 'completeGrant entry failed: $e');
  }
}
