/// Deterministic artwork for the Nyctis comparison scenarios.
///
/// The Widgetbook fixtures use a single 1x1 pixel, which proves the decode
/// path but gives a reviewer nothing to look at. These are small, real PNGs
/// drawn from arithmetic alone: the same bytes on every run and every host, so
/// a pixel difference between two captures is a UI difference and never an
/// artwork one. Nothing is read from disk or the network.
library;

import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';

const int _side = 128;

/// One piece of the moon collection: a night sky whose hue drifts with
/// [index] and a moon whose phase advances with it.
Uint8List nyctisCaptureMoonPng(int index) {
  final cached = _moonCache[index];
  if (cached != null) return cached;
  final canvas = _Canvas(_side, _side);
  final hue = (220 + index * 23) % 360;
  final top = _hsv(hue.toDouble(), 0.55, 0.22);
  final bottom = _hsv(((hue + 40) % 360).toDouble(), 0.65, 0.42);
  canvas.verticalGradient(top, bottom);
  canvas.stars(seed: 97 + index * 31, count: 22);
  // Phase in [0, 1): 0 is new, 0.5 is full.
  final phase = ((index * 0.125) + 0.0625) % 1.0;
  canvas.moon(
    cx: 64,
    cy: 60,
    radius: 34,
    phase: phase,
    light: const [246, 236, 200],
    dark: _mix(top, const [20, 20, 30], 0.4),
  );
  final png = canvas.encode();
  _moonCache[index] = png;
  return png;
}

final Map<int, Uint8List> _moonCache = {};

/// The collection's own declared logo: a full moon in a ring.
final Uint8List kNyctisCaptureCollectionLogoPng = () {
  final canvas = _Canvas(_side, _side);
  canvas.verticalGradient(const [12, 14, 38], const [44, 28, 76]);
  canvas.stars(seed: 5, count: 30);
  canvas.ring(
    cx: 64,
    cy: 64,
    radius: 52,
    width: 5,
    color: const [214, 196, 255],
  );
  canvas.moon(
    cx: 64,
    cy: 64,
    radius: 34,
    phase: 0.5,
    light: const [250, 244, 214],
    dark: const [20, 20, 30],
  );
  return canvas.encode();
}();

/// An issuer logo for a fungible asset: a teal disc with a ring and a mark.
final Uint8List kNyctisCaptureHarbourLogoPng = () {
  final canvas = _Canvas(_side, _side);
  canvas.fill(const [0, 0, 0, 0]);
  canvas.disc(cx: 64, cy: 64, radius: 62, color: const [16, 124, 132]);
  canvas.ring(
    cx: 64,
    cy: 64,
    radius: 50,
    width: 6,
    color: const [236, 250, 248],
  );
  canvas.rect(58, 30, 70, 94, const [236, 250, 248]);
  canvas.rect(42, 44, 86, 54, const [236, 250, 248]);
  canvas.ring(
    cx: 64,
    cy: 70,
    radius: 24,
    width: 6,
    color: const [236, 250, 248],
    lowerHalfOnly: true,
  );
  return canvas.encode();
}();

/// A second issuer logo, for the uncapped ticket collection's pieces.
Uint8List nyctisCaptureTicketPng(int index) {
  final canvas = _Canvas(_side, _side);
  final hue = (18 + index * 41) % 360;
  canvas.verticalGradient(
    _hsv(hue.toDouble(), 0.7, 0.85),
    _hsv(((hue + 30) % 360).toDouble(), 0.8, 0.55),
  );
  canvas.rect(20, 40, 108, 88, const [252, 248, 240]);
  canvas.disc(
    cx: 20,
    cy: 64,
    radius: 10,
    color: _hsv(hue.toDouble(), 0.7, 0.8),
  );
  canvas.disc(
    cx: 108,
    cy: 64,
    radius: 10,
    color: _hsv(hue.toDouble(), 0.7, 0.8),
  );
  for (var x = 36; x < 96; x += 8) {
    canvas.rect(x, 52, x + 4, 76, _hsv(hue.toDouble(), 0.5, 0.35));
  }
  return canvas.encode();
}

// ---------------------------------------------------------------------------

class _Canvas {
  _Canvas(this.width, this.height) : pixels = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;

  void fill(List<int> rgba) {
    for (var i = 0; i < width * height; i++) {
      pixels.setRange(i * 4, i * 4 + 4, rgba);
    }
  }

  void verticalGradient(List<int> top, List<int> bottom) {
    for (var y = 0; y < height; y++) {
      final c = _mix(top, bottom, y / (height - 1));
      for (var x = 0; x < width; x++) {
        _set(x, y, c, 1);
      }
    }
  }

  void stars({required int seed, required int count}) {
    final random = math.Random(seed);
    for (var i = 0; i < count; i++) {
      final x = random.nextInt(width);
      final y = random.nextInt(height);
      final bright = 150 + random.nextInt(100);
      _blend(x, y, [bright, bright, bright], 0.9);
    }
  }

  void disc({
    required double cx,
    required double cy,
    required double radius,
    required List<int> color,
  }) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final d = math.sqrt(_sq(x + 0.5 - cx) + _sq(y + 0.5 - cy));
        final cover = (radius - d + 0.5).clamp(0.0, 1.0);
        if (cover > 0) _blend(x, y, color, cover);
      }
    }
  }

  void ring({
    required double cx,
    required double cy,
    required double radius,
    required double width,
    required List<int> color,
    bool lowerHalfOnly = false,
  }) {
    for (var y = 0; y < height; y++) {
      if (lowerHalfOnly && y + 0.5 < cy) continue;
      for (var x = 0; x < this.width; x++) {
        final d = math.sqrt(_sq(x + 0.5 - cx) + _sq(y + 0.5 - cy));
        final cover = (width / 2 - (d - radius).abs() + 0.5).clamp(0.0, 1.0);
        if (cover > 0) _blend(x, y, color, cover);
      }
    }
  }

  void rect(int x0, int y0, int x1, int y1, List<int> color) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        _set(x, y, color, 1);
      }
    }
  }

  /// A lit disc with a terminator. [phase] 0 is new, 0.5 full, 1 new again.
  void moon({
    required double cx,
    required double cy,
    required double radius,
    required double phase,
    required List<int> light,
    required List<int> dark,
  }) {
    // The terminator is an ellipse whose half-width follows the phase.
    final k = math.cos(phase * 2 * math.pi); // 1 new, -1 full
    final waxing = phase < 0.5;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final dx = x + 0.5 - cx;
        final dy = y + 0.5 - cy;
        final d = math.sqrt(dx * dx + dy * dy);
        final cover = (radius - d + 0.5).clamp(0.0, 1.0);
        if (cover <= 0) continue;
        final halfChord = math.sqrt(math.max(0, radius * radius - dy * dy));
        final edge = halfChord * k;
        // Waxing: lit on the right of the terminator; waning: on the left.
        final lit = waxing ? dx > edge : dx < -edge;
        // A little limb darkening, so the disc reads as a sphere.
        final shade = 1 - 0.18 * math.pow(d / radius, 3);
        final base = lit ? light : dark;
        _blend(x, y, [
          (base[0] * shade).round(),
          (base[1] * shade).round(),
          (base[2] * shade).round(),
        ], cover);
      }
    }
  }

  void _set(int x, int y, List<int> rgb, double alpha) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 4;
    pixels[i] = rgb[0];
    pixels[i + 1] = rgb[1];
    pixels[i + 2] = rgb[2];
    pixels[i + 3] = (alpha * 255).round();
  }

  void _blend(int x, int y, List<int> rgb, double alpha) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 4;
    final a0 = pixels[i + 3] / 255;
    final a = alpha + a0 * (1 - alpha);
    if (a <= 0) return;
    for (var c = 0; c < 3; c++) {
      pixels[i + c] = ((rgb[c] * alpha + pixels[i + c] * a0 * (1 - alpha)) / a)
          .round()
          .clamp(0, 255);
    }
    pixels[i + 3] = (a * 255).round();
  }

  Uint8List encode() => _encodePng(width, height, pixels);
}

double _sq(double v) => v * v;

List<int> _mix(List<int> a, List<int> b, double t) => [
  for (var i = 0; i < 3; i++) (a[i] + (b[i] - a[i]) * t).round(),
];

List<int> _hsv(double h, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  final (r, g, b) = switch (h) {
    < 60 => (c, x, 0.0),
    < 120 => (x, c, 0.0),
    < 180 => (0.0, c, x),
    < 240 => (0.0, x, c),
    < 300 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return [
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  ];
}

Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  _chunk(out, 'IDAT', ZLibCodec(level: 9).encode(raw.takeBytes()));
  _chunk(out, 'IEND', const []);
  return out.takeBytes();
}

void _chunk(BytesBuilder out, String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final length = ByteData(4)..setUint32(0, data.length);
  out.add(length.buffer.asUint8List());
  out.add(typeBytes);
  out.add(data);
  final crc = ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]));
  out.add(crc.buffer.asUint8List());
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
