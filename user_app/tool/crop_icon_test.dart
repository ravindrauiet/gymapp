// Builds clean icon files from assets/icon/app_icon.png (the neon F-key tile, which has light background bands
// around it). Run: flutter test tool/crop_icon_test.dart  — then: dart run flutter_launcher_icons
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('build app icon variants', () {
    final src = img.decodeImage(File('assets/icon/app_icon.png').readAsBytesSync())!;
    // Inner square of the rounded dark tile (the tile spans ~105–920 px of the 1024 px image; its corners are
    // rounded, so stay inside them). The F-key artwork sits fully within this square.
    const x = 175, y = 175, size = 675;
    final tile = img.copyCrop(src, x: x, y: y, width: size, height: size);
    File('assets/icon/app_icon_tile.png').writeAsBytesSync(img.encodePng(tile));

    // Full-bleed 1024 px: legacy launcher icon, iOS, store listing.
    final full = img.copyResize(tile, width: 1024, height: 1024, interpolation: img.Interpolation.cubic);
    File('assets/icon/app_icon_full.png').writeAsBytesSync(img.encodePng(full));

    // Adaptive foreground: the tile at 72% inside a transparent 1024 canvas, so launcher masks (circle, squircle)
    // never cut the F-key; the background layer is the tile's own dark colour (see pubspec).
    final fg = img.Image(width: 1024, height: 1024, numChannels: 4);
    final inner = img.copyResize(tile, width: 736, height: 736, interpolation: img.Interpolation.cubic);
    // Feather the tile's edge so its texture fades into the flat background layer instead of leaving a seam.
    const feather = 90;
    final soft = img.Image(width: 736, height: 736, numChannels: 4);
    for (var yy = 0; yy < 736; yy++) {
      for (var xx = 0; xx < 736; xx++) {
        final edge = [xx, yy, 735 - xx, 735 - yy].reduce((a, b) => a < b ? a : b);
        final t = (edge / feather).clamp(0.0, 1.0);
        final p = inner.getPixel(xx, yy);
        soft.setPixelRgba(xx, yy, p.r, p.g, p.b, (255 * t * t * (3 - 2 * t)).round());
      }
    }
    img.compositeImage(fg, soft, dstX: 144, dstY: 144);

    // Native Android launch-screen logo (96 dp, rounded tile) at every density.
    const densities = {'mdpi': 96, 'hdpi': 144, 'xhdpi': 192, 'xxhdpi': 288, 'xxxhdpi': 384};
    densities.forEach((dir, px) {
      final logo = img.copyResize(tile, width: px, height: px, interpolation: img.Interpolation.cubic);
      final rounded = img.Image(width: px, height: px, numChannels: 4);
      final r = px * 0.24;
      for (var yy = 0; yy < px; yy++) {
        for (var xx = 0; xx < px; xx++) {
          final cx = xx < r ? r : (xx > px - 1 - r ? px - 1 - r : xx.toDouble());
          final cy = yy < r ? r : (yy > px - 1 - r ? px - 1 - r : yy.toDouble());
          final d = ((xx - cx) * (xx - cx) + (yy - cy) * (yy - cy));
          final a = d <= (r - 1) * (r - 1) ? 255 : (d >= r * r ? 0 : 128);
          final p = logo.getPixel(xx, yy);
          rounded.setPixelRgba(xx, yy, p.r, p.g, p.b, a);
        }
      }
      File('android/app/src/main/res/drawable-$dir/splash_logo.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(img.encodePng(rounded));
    });
    File('assets/icon/app_icon_foreground.png').writeAsBytesSync(img.encodePng(fg));

    // Average colour of the tile's corner = adaptive background colour.
    var r = 0, g = 0, b = 0, n = 0;
    for (var yy = 0; yy < 60; yy++) {
      for (var xx = 0; xx < 60; xx++) {
        final p = tile.getPixel(xx, yy);
        r += p.r.toInt();
        g += p.g.toInt();
        b += p.b.toInt();
        n++;
      }
    }
    String hex(int v) => (v ~/ n).toRadixString(16).padLeft(2, '0');
    File('assets/icon/background_color.txt').writeAsStringSync('#${hex(r)}${hex(g)}${hex(b)}'.toUpperCase());
  });
}
