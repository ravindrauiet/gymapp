import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'screens/auth/login_screen.dart';
import 'screens/auth/profile_screen.dart';
import 'screens/home/dashboard_screen.dart';
import 'state/partner_session.dart';
import 'ui/ui.dart';
import 'widgets/brand.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('en_IN');
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(ChangeNotifierProvider(create: (_) => PartnerSession()..restore(), child: const FitKeyPartnerApp()));
}

class FitKeyPartnerApp extends StatelessWidget {
  const FitKeyPartnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FITKEY Partner',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // On wide screens (web / tablets) keep a phone-width column, like the member app.
      builder: (context, child) {
        if (child == null) return const SizedBox.shrink();
        final media = MediaQuery.of(context);
        if (media.size.width <= 520) return child;
        return ColoredBox(
          color: const Color(0xFF07090E),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: MediaQuery(data: media.copyWith(size: Size(480, media.size.height)), child: ClipRect(child: child)),
            ),
          ),
        );
      },
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
      duration: const Duration(milliseconds: 350),
      child: switch (status) {
        SessionStatus.loading => const Scaffold(
            backgroundColor: AppColors.ink,
            body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                PartnerLockup(size: 44, light: true),
                SizedBox(height: 36),
                SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.lime)),
              ]),
            ),
          ),
        SessionStatus.signedOut => const LoginScreen(),
        SessionStatus.needsProfile => const ProfileScreen(),
        SessionStatus.signedIn => const DashboardScreen(),
      },
    );
  }
}
