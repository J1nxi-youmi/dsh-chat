import 'dart:typed_data';
import 'dart:ui' as ui;

/// Flutter 的 Image 不认 BMP，而相册/截图工具里 BMP 很常见（还常被改名成 .png/.jpg）。
/// 兜底：检测到 BMP 就解码后转成 PNG，其它格式原样返回。
Future<Uint8List> normalizeImageBytes(Uint8List bytes, String mime) async {
  if (mime != 'image/bmp' && mime != 'image/x-ms-bmp') return bytes;
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  return png?.buffer.asUint8List() ?? bytes;
}
