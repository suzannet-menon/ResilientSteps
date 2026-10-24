import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config/app_config.dart';
import 'widgets/auth_gate.dart';

Future<void> main() async {
  // Ensures plugins (maps, location, storage) are initialized before runApp.
  WidgetsFlutterBinding.ensureInitialized();

  // Runtime config validation — these survive release builds (assert does not).
  if (AppConfig.apiBaseUrl.isEmpty) {
    throw StateError(
      'API_BASE_URL must be set. '
      'Run flutter with: --dart-define-from-file=config/dart_defines.json',
    );
  }
  if (AppConfig.maptilerApiKey.isEmpty) {
    throw StateError(
      'MAPTILER_API_KEY must be set via --dart-define or dart_defines.json',
    );
  }
  if (AppConfig.supabaseUrl.isEmpty) {
    throw StateError(
      'SUPABASE_URL must be set via --dart-define or dart_defines.json',
    );
  }
  if (AppConfig.supabaseAnonKey.isEmpty) {
    throw StateError(
      'SUPABASE_ANON_KEY must be set via --dart-define or dart_defines.json',
    );
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  final String supabaseHost =
      Uri.tryParse(AppConfig.supabaseUrl)?.host ?? 'unknown';
  debugPrint('Supabase initialized with endpoint host: $supabaseHost');

  await Hive.initFlutter();
  await Hive.openBox('walksafe_saved_places');

  runApp(const WalkSafeApp());
}

class WalkSafeApp extends StatelessWidget {
  const WalkSafeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2E7CF6),
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );

    return MaterialApp(
      title: 'ResilientSteps',
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: Color(0xFF142032),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
        ),
        textTheme: baseTheme.textTheme.apply(
          bodyColor: const Color(0xFF142032),
          displayColor: const Color(0xFF142032),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF142032),
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const AuthGate(),
    );
  }
}
