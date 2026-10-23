import 'dart:typed_data';
import 'dart:ui' as ui;

/// Art bytes bounded for both disk and RAM.
///
/// Embedded covers arrive at whatever size the ripper felt like: the
/// reader accepts up to 24 MB per image (a legal 12000 px scan), and a
/// file that size decodes to roughly half a gigabyte of RGBA the
/// moment anything draws it — list tile, hero, or the notification.
/// On a low-RAM phone that is the whole process.
///
/// The engine decodes straight to the target size
/// (`ImageDescriptor.instantiateCodec`), so the full-size bitmap never
/// exists. Output is PNG because `dart:ui` has no JPEG encoder; at
/// 1024 px that lands in the low hundreds of KB, which is well under
/// the old raw write.
///
/// Never loses art: any failure returns the input untouched.
const int artMaxPx = 1024;

/// Below this an image is already cheap enough to keep as-is.
const int artShrinkFloor = 600 * 1024;

Future<Uint8List> shrinkArt(
  Uint8List bytes, {
  int maxPx = artMaxPx,
  int floorBytes = artShrinkFloor,
}) async {
  if (bytes.isEmpty) return bytes;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    if (w <= 0 || h <= 0) return bytes;
    final longest = w > h ? w : h;
    // Already small on both axes and light on disk: nothing to win.
    if (longest <= maxPx && bytes.length <= floorBytes) return bytes;
    final scale = longest > maxPx ? maxPx / longest : 1.0;
    final targetW = (w * scale).round().clamp(1, maxPx);
    final targetH = (h * scale).round().clamp(1, maxPx);
    codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return bytes;
    final out = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    // A re-encode that somehow grew is not worth keeping.
    return out.length < bytes.length ? out : bytes;
  } catch (_) {
    return bytes;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}
