import 'package:flutter/services.dart';

/// Spike ONLY: narrow OkHttp chunk fetch over the
/// `arch.player/okhttp` platform channel (real Square OkHttp,
/// android/app dependency). Used only by [TransportSpike];
/// playback never touches this.
abstract final class OkHttpChunk {
  static const _channel = MethodChannel('arch.player/okhttp');

  /// GET [url] with [headers], read up to 64KB of the body to prove
  /// bytes flowed. Returns the status code, or -1 on transport
  /// failure. Never throws.
  static Future<({int status, int bytes, String? error})> fetchChunk(
    String url,
    Map<String, String> headers,
  ) async {
    try {
      final res = await _channel.invokeMethod<Map<Object?, Object?>>(
        'fetchChunk',
        {'url': url, 'headers': headers},
      );
      if (res == null) return (status: -1, bytes: 0, error: 'null reply');
      final status = res['status'];
      final bytes = res['bytes'];
      final error = res['error'];
      return (
        status: status is int ? status : -1,
        bytes: bytes is int ? bytes : 0,
        error: error?.toString(),
      );
    } on PlatformException catch (e) {
      return (status: -1, bytes: 0, error: e.message ?? e.code);
    } catch (e) {
      return (status: -1, bytes: 0, error: '$e');
    }
  }
}
