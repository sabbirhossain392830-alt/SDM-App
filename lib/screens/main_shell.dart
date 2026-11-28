import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../browser/browser_controller.dart';
import '../browser/browser_screen.dart';
import '../l10n.dart';
import 'app_settings_screen.dart';
import 'home_screen.dart';

/// The app's main screen: three tabs at the bottom.
/// Download (logo + search box), Play (speed card, filters, downloads), Settings.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _i = 0;
  final _browser = BrowserController.instance;
  bool _browserBuilt = false; // built the first time it is opened, then kept
  final GlobalKey<NavigatorState> _settingsNav = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final accent = dark ? const Color(0xFF6FA3FF) : const Color(0xFF4A5BE0);
    Widget dest(IconData icon, String label) => NavigationDestination(
          icon: Icon(icon, color: cs.outline),
          selectedIcon: Icon(icon, color: accent),
          label: tr(label),
        );
    return ValueListenableBuilder<bool>(
      valueListenable: _browser.visible,
      builder: (context, showBrowser, _) {
        if (showBrowser) _browserBuilt = true;
        return PopScope(
          canPop: _i == 0 && !showBrowser,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || showBrowser) return; // the browser handles its own back
            // inside a settings page: go back one page first
            final n = _settingsNav.currentState;
            if (_i == 2 && n != null && n.canPop()) {
              n.pop();
            } else {
              setState(() => _i = 0);
            }
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: IndexedStack(
              index: showBrowser ? 3 : _i,
              children: [
                const HomeScreen(tab: true),
                const HomeScreen(library: true),
                // its own navigator: settings pages open inside the tab, so
                // the bottom bar stays
                Navigator(
                  key: _settingsNav,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => const AppSettingsScreen()),
                ),
                if (_browserBuilt)
                  const BrowserScreen()
                else
                  const SizedBox.shrink(),
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
                      color:
                          s.contains(WidgetState.selected) ? accent : cs.outline,
                    )),
              ),
              child: NavigationBar(
                selectedIndex: showBrowser ? 0 : _i,
                onDestinationSelected: (v) {
                  HapticFeedback.selectionClick();
                  _browser.closeScreen();
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
      },
    );
  }
}
