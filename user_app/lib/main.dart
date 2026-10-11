import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_setup_screen.dart';
import 'screens/home/home_shell.dart';
import 'screens/splash_screen.dart';
import 'state/session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(ChangeNotifierProvider(create: (_) => Session()..restore(), child: const FitKeyApp()));
}

class FitKeyApp extends StatelessWidget {
  const FitKeyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FITKEY',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _SessionGate(),
    );
  }
}

/// Swaps the root screen as the session moves between signed-out, profile setup and signed-in.
class _SessionGate extends StatelessWidget {
  const _SessionGate();

  @override
  Widget build(BuildContext context) {
    final status = context.select<Session, SessionStatus>((s) => s.status);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: switch (status) {
        SessionStatus.loading => const SplashScreen(),
        SessionStatus.signedOut => const LoginScreen(),
        SessionStatus.needsProfile => const ProfileSetupScreen(),
        SessionStatus.signedIn => const HomeShell(),
      },
    );
  }
}
