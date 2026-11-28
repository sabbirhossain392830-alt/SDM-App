import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import 'app_settings_screen.dart';
import 'home_screen.dart';
import 'play_tab.dart';

/// The app's main screen: three tabs at the bottom.
/// Download (search box + downloads), Play (videos and songs), Settings.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final accent = dark ? const Color(0xFFFFC800) : cs.primary;
    Widget dest(IconData icon, String label) => NavigationDestination(
          icon: Icon(icon, color: cs.outline),
          selectedIcon: Icon(icon, color: accent),
          label: tr(label),
        );
    return PopScope(
      canPop: _i == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _i = 0);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _i,
          children: [
            const HomeScreen(tab: true),
            PlayTab(active: _i == 1),
            const AppSettingsScreen(),
          ],
        ),
        bottomNavigationBar: NavigationBarTheme(
          data: NavigationBarThemeData(
            height: 68,
            indicatorColor: Colors.transparent,
            backgroundColor: dark ? const Color(0xFF141414) : null,
            labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                  fontSize: 12.5,
                  fontWeight: s.contains(WidgetState.selected)
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: s.contains(WidgetState.selected) ? accent : cs.outline,
                )),
          ),
          child: NavigationBar(
            selectedIndex: _i,
            onDestinationSelected: (v) {
              HapticFeedback.selectionClick();
              setState(() => _i = v);
            },
            destinations: [
              dest(Icons.search_rounded, 'Download'),
              dest(Icons.play_circle_outline_rounded, 'Play'),
              dest(Icons.settings_outlined, 'Settings'),
            ],
          ),
        ),
      ),
    );
  }
}
