import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_setup_screen.dart';
import 'screens/home/home_shell.dart';
import 'screens/splash_screen.dart';
import 'state/cart.dart';
import 'state/session.dart';
import 'ui/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => Session()..restore()),
      ChangeNotifierProvider(create: (_) => Cart()),
    ],
    child: const FitKeyApp(),
  ));
}

class FitKeyApp extends StatelessWidget {
  const FitKeyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FITKEY',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        if (media.size.width <= 520) {
          return child;
        }
        return Container(
          color: const Color(0xFF07090E),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(480, media.size.height),
                ),
                child: ClipRect(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 30,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
      duration: const Duration(milliseconds: 350),
      child: switch (status) {
        SessionStatus.loading => const SplashScreen(),
        SessionStatus.signedOut => const LoginScreen(),
        SessionStatus.needsProfile => const ProfileSetupScreen(),
        SessionStatus.signedIn => const HomeShell(),
      },
    );
  }
}
