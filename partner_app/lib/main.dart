import 'package:fitkey_core/fitkey_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_screen.dart';
import 'screens/home/dashboard_screen.dart';
import 'state/partner_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(ChangeNotifierProvider(create: (_) => PartnerSession()..restore(), child: const FitKeyPartnerApp()));
}

class FitKeyPartnerApp extends StatelessWidget {
  const FitKeyPartnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FITKEY Partner',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _SessionGate(),
    );
  }
}

class _SessionGate extends StatelessWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context) {
    final status = context.select<PartnerSession, SessionStatus>((s) => s.status);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: switch (status) {
        SessionStatus.loading => const Scaffold(body: Center(child: FitKeyLogo(size: 52, tag: 'PARTNER'))),
        SessionStatus.signedOut => const LoginScreen(),
        SessionStatus.needsProfile => const ProfileScreen(),
        SessionStatus.signedIn => const DashboardScreen(),
      },
    );
  }
}
