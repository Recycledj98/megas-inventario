import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'services/config_service.dart';
import 'screens/config_screen.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConfigService.init();
  runApp(const ProviderScope(child: MegasInventarioApp()));
}

final _router = GoRouter(
  initialLocation: '/splash',
  redirect: (context, state) {
    if (state.matchedLocation == '/splash') return null;
    if (!ConfigService.isConfigured && state.matchedLocation != '/config') {
      return '/config';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/splash',
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/config',
      builder: (context, state) {
        final isInitial = !ConfigService.isConfigured;
        return ConfigScreen(isInitialSetup: isInitial);
      },
    ),
  ],
);

class MegasInventarioApp extends StatelessWidget {
  const MegasInventarioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Megas Inventario',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
    );
  }
}

// ── Splash Screen ─────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  static const _kBg       = Color(0xFF0A1628);
  static const _kAccent   = Color(0xFF1A73E8);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fade  = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    _ctrl.forward();

    Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      context.go(ConfigService.isConfigured ? '/' : '/config');
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: _kBg,
      body: Stack(
        children: [
          // Círculo decorativo superior-derecha
          Positioned(
            top: -size.width * 0.25,
            right: -size.width * 0.15,
            child: Container(
              width: size.width * 0.75,
              height: size.width * 0.75,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    _kAccent.withAlpha(35),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Círculo decorativo inferior-izquierda
          Positioned(
            bottom: -size.width * 0.2,
            left: -size.width * 0.2,
            child: Container(
              width: size.width * 0.65,
              height: size.width * 0.65,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    _kAccent.withAlpha(20),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Contenido central
          Center(
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Tarjeta con logo
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(12),
                        borderRadius: BorderRadius.circular(32),
                        border: Border.all(
                          color: Colors.white.withAlpha(20),
                        ),
                      ),
                      padding: const EdgeInsets.all(24),
                      child: Image.asset(
                        'assets/images/negro.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.inventory_2_rounded,
                          size: 64,
                          color: _kAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 36),

                    // Nombre
                    const Text(
                      'MEGAS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 7,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'INVENTARIO',
                      style: TextStyle(
                        color: _kAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 9,
                      ),
                    ),

                    const SizedBox(height: 72),

                    // Spinner sutil
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Colors.white.withAlpha(60),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Versión abajo
          Positioned(
            bottom: 28,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _fade,
              child: Text(
                'v1.2.9',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withAlpha(45),
                  fontSize: 11,
                  letterSpacing: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tema ──────────────────────────────────────────────────────────────────────

ThemeData _buildTheme(Brightness brightness) {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1A73E8),
    brightness: brightness,
  );

  final base = brightness == Brightness.light
      ? ThemeData.light(useMaterial3: true)
      : ThemeData.dark(useMaterial3: true);

  return base.copyWith(
    colorScheme: colorScheme,
    textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
      displayLarge:  GoogleFonts.inter(fontSize: 32, fontWeight: FontWeight.w700),
      displayMedium: GoogleFonts.inter(fontSize: 26, fontWeight: FontWeight.w700),
      titleLarge:    GoogleFonts.inter(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium:   GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
      titleSmall:    GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
      bodyLarge:     GoogleFonts.inter(fontSize: 16),
      bodyMedium:    GoogleFonts.inter(fontSize: 14),
      bodySmall:     GoogleFonts.inter(fontSize: 12),
      labelLarge:    GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      filled: true,
      fillColor: colorScheme.surfaceContainerHighest,
      labelStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant.withAlpha(140)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}
