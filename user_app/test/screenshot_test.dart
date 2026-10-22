// Renders key screens to PNGs for a visual check: flutter test test/screenshot_test.dart --update-goldens
import 'dart:io';

import 'package:fitkey_user/screens/auth/login_screen.dart';
import 'package:fitkey_user/screens/nutrition/ai_food_scanner.dart';
import 'package:fitkey_user/state/cart.dart';
import 'package:fitkey_user/state/session.dart';
import 'package:fitkey_user/ui/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Future<void> _loadFonts() async {
  final jakarta = FontLoader(kFont);
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    jakarta.addFont(Future.value(ByteData.sublistView(File('assets/fonts/PlusJakartaSans-$w.ttf').readAsBytesSync())));
  }
  await jakarta.load();
  final icons = FontLoader('MaterialIcons');
  final sdk = Platform.environment['FLUTTER_ROOT']!;
  icons.addFont(Future.value(ByteData.sublistView(
      File('$sdk/bin/cache/artifacts/material_fonts/materialicons-regular.otf').readAsBytesSync())));
  await icons.load();
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shoot(WidgetTester tester, Widget screen, String name) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => Session()),
        ChangeNotifierProvider(create: (_) => Cart()),
      ],
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildAppTheme(), home: screen),
    ));
    await tester.runAsync(() async {
      for (final e in find.byType(Image).evaluate()) {
        await precacheImage((e.widget as Image).image, e);
      }
    });
    await tester.pump(const Duration(milliseconds: 500));
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('login', (t) => shoot(t, const LoginScreen(), 'login'));
  testWidgets('meal scanner', (t) => shoot(t, const AiFoodScannerScreen(), 'scanner'));
}
