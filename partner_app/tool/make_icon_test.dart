// Generates the launcher icon PNGs into assets/icon/. Run: flutter test tool/make_icon_test.dart, then dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fitkey_partner/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _fonts() async {
  final f = FontLoader(kFont)
    ..addFont(Future.value(ByteData.sublistView(File('assets/fonts/PlusJakartaSans-ExtraBold.ttf').readAsBytesSync())));
  await f.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File(
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/materialicons-regular.otf')
        .readAsBytesSync())));
  await icons.load();
}

late ui.Image _tile;

/// The mark: the real FITKEY app tile (assets/icon/app_icon_tile.png) with an ember PARTNER band.
/// [scale] shrinks it for the adaptive safe zone.
Widget _mark(double scale, {required bool background}) => Container(
      width: 1024,
      height: 1024,
      color: background ? const Color(0xFF151619) : Colors.transparent,
      alignment: Alignment.center,
      child: Transform.scale(
        scale: scale,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(140),
            child: SizedBox(width: 600, height: 600, child: RawImage(image: _tile, fit: BoxFit.cover)),
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 46, vertical: 14),
            decoration: BoxDecoration(color: AppColors.primary, borderRadius: BorderRadius.circular(40)),
            child: const Text('PARTNER',
                style: TextStyle(
                    fontFamily: kFont, fontSize: 92, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 8)),
          ),
        ]),
      ),
    );

Future<void> _save(WidgetTester tester, Widget w, String path) async {
  final key = GlobalKey();
  await tester.pumpWidget(Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: RepaintBoundary(key: key, child: w)),
  ));
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(_fonts);
  testWidgets('make launcher icons', (tester) async {
    tester.view.physicalSize = const Size(1024, 1024);
    tester.view.devicePixelRatio = 1;
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File('assets/icon/app_icon_tile.png').readAsBytesSync());
      _tile = (await codec.getNextFrame()).image;
    });
    // Full icon (legacy launchers, iOS, Play Store listing).
    await _save(tester, _mark(0.82, background: true), 'assets/icon/app_icon.png');
    // Adaptive foreground: content inside the central ~60% safe zone, transparent around it.
    await _save(tester, _mark(0.56, background: false), 'assets/icon/app_icon_foreground.png');
  });
}
