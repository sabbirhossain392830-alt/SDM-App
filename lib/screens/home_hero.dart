import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../browser/browser_controller.dart';
import '../browser/download_prompt.dart';
import '../l10n.dart';

/// The start page of SDM: the title, the search box and the shortcuts. It is
/// the Download tab and also the new-tab page of the browser.
class HomeHero extends StatefulWidget {
  /// A web address or words typed in the box ('' = just open the browser).
  final Future<void> Function(String text) onSubmit;

  /// A shortcut was tapped.
  final void Function(String url) onSite;
  const HomeHero({super.key, required this.onSubmit, required this.onSite});

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // fetch the logo of every shortcut that has none yet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final b = BrowserController.instance;
      for (final s in b.shortcuts) {
        b.ensureIcon(s.url);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // the colours of the SDM logo (blue vault)
  static const _gold = Color(0xFF6FA3FF);
  static const _blueDeep = Color(0xFF4A5BE0);

  static bool _looksLikeFileLink(String t) {
    final u = Uri.tryParse(t);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return false;
    final last = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
    final m = RegExp(r'\.([A-Za-z0-9]{2,5})$').firstMatch(last);
    if (m == null) return false;
    const pages = {'html', 'htm', 'php', 'asp', 'aspx', 'jsp', 'xhtml'};
    return !pages.contains(m.group(1)!.toLowerCase());
  }

  /// Search box: a file link starts the download popup, a web address or
  /// words open the browser.
  Future<void> _go(String text) async {
    final t = text.trim();
    FocusManager.instance.primaryFocus?.unfocus();
    if (t.isEmpty) {
      await widget.onSubmit('');
      return;
    }
    _search.clear();
    if (_looksLikeFileLink(t)) {
      if (!mounted) return;
      await showDownloadPrompt(context, DownloadRequest(url: t));
    } else {
      await widget.onSubmit(t);
    }
  }

  Future<void> _pasteIntoSearch() async {
    final c = await Clipboard.getData('text/plain');
    final t = c?.text?.trim();
    if (t == null || t.isEmpty) return;
    setState(() => _search.text = t);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final accent = dark ? _gold : _blueDeep;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 40, 18, 10),
      child: Column(children: [
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0xFF4040D0), Color(0xFF6090F0)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(r),
          blendMode: BlendMode.srcIn,
          child: const Text('SDM',
              style: TextStyle(
                  fontSize: 58,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                  color: Colors.white)),
        ),
        const SizedBox(height: 30),
        Container(
          height: 58,
          decoration: BoxDecoration(
            color: dark ? Colors.white.withValues(alpha: 0.04) : cs.surface,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(children: [
            IconButton(
              tooltip: tr('Paste'),
              icon: Icon(Icons.file_download_outlined, color: cs.outline),
              onPressed: _pasteIntoSearch,
            ),
            Expanded(
              child: TextField(
                controller: _search,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.search,
                onSubmitted: _go,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: tr('Search to download'),
                  filled: false,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton.filled(
                style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFF4F6FF0),
                    foregroundColor: Colors.white,
                    fixedSize: const Size(46, 46)),
                icon: const Icon(Icons.search_rounded),
                onPressed: () => _go(_search.text),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 22),
        _shortcuts(),
      ]),
    );
  }

  /// Sites under the search box. Tap opens the site in the browser, long press
  /// removes it, and the + button adds a new one.
  Widget _shortcuts() {
    final cs = Theme.of(context).colorScheme;
    final dark = cs.brightness == Brightness.dark;
    final accent = dark ? _gold : _blueDeep;
    final b = BrowserController.instance;
    Widget tile(Widget child, String label,
            {VoidCallback? onTap, VoidCallback? onLong, bool logo = false}) =>
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: onLong,
          child: SizedBox(
            width: 74,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  // a site logo sits on white so dark logos stay visible
                  color: logo
                      ? Colors.white
                      : cs.onSurface.withValues(alpha: 0.07),
                  shape: BoxShape.circle,
                ),
                child: child,
              ),
              const SizedBox(height: 6),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
            ]),
          ),
        );
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) => Wrap(
        alignment: WrapAlignment.center,
        spacing: 4,
        runSpacing: 10,
        children: [
          for (final sc in b.shortcuts.take(11))
            tile(
              _logo(b.iconFor(sc.url), sc.name, accent),
              sc.name,
              logo: b.iconFor(sc.url) != null,
              onTap: () => widget.onSite(sc.url),
              onLong: () => _removeShortcut(sc),
            ),
          tile(Icon(Icons.add_rounded, color: accent), tr('Add shortcut'),
              onTap: _addShortcut),
        ],
      ),
    );
  }

  Widget _logo(Uint8List? icon, String name, Color accent) {
    final letter = Text(name.isEmpty ? '?' : name[0].toUpperCase(),
        style:
            TextStyle(fontWeight: FontWeight.w800, fontSize: 19, color: accent));
    if (icon == null) return letter;
    return ClipOval(
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: Image.memory(icon,
            width: 30,
            height: 30,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => letter),
      ),
    );
  }

  Future<void> _addShortcut() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const T('Add shortcut'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: name,
            decoration: InputDecoration(hintText: tr('Name')),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(hintText: tr('Website address')),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const T('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const T('Add')),
        ],
      ),
    );
    final u = url.text.trim();
    if (ok == true && u.isNotEmpty) {
      await BrowserController.instance.addShortcut(name.text, u);
    }
  }

  Future<void> _removeShortcut(Shortcut sc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(sc.name),
        content: const T('Remove this shortcut?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const T('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const T('Remove')),
        ],
      ),
    );
    if (ok == true) await BrowserController.instance.removeShortcut(sc);
  }
}
