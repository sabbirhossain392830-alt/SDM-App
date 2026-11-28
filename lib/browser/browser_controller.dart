import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../download_manager.dart';
import '../hls.dart';
import 'browser_tab.dart';

/// Route name of the browser screen (used to come back to it).
const String kBrowserRoute = 'drom_browser';

class Shortcut {
  final String name;
  final String url;
  const Shortcut(this.name, this.url);
  Map<String, dynamic> toJson() => {'name': name, 'url': url};
  factory Shortcut.fromJson(Map<String, dynamic> j) =>
      Shortcut(j['name'] as String, j['url'] as String);
}

class HistoryEntry {
  final String title;
  final String url;
  final int time; // millisecondsSinceEpoch
  const HistoryEntry(this.title, this.url, this.time);
  Map<String, dynamic> toJson() => {'t': title, 'u': url, 'm': time};
  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
      j['t'] as String, j['u'] as String, (j['m'] as num).toInt());
}

/// Domains / patterns blocked when "Block Ads" is on.
/// Ad, tracker and pop-up networks. One list serves two jobs: the page
/// requests to these hosts are blocked, and a page that tries to send the
/// whole tab to one of them (ad redirects) is stopped.
const List<String> _adDomains = [
  // Google / big ad exchanges
  'doubleclick.net', 'googlesyndication.com', 'googleadservices.com',
  'adservice.google.com', 'google-analytics.com', 'googletagmanager.com',
  'googletagservices.com', 'adsense.com', 'admob.com',
  'amazon-adsystem.com', 'adnxs.com', 'adsrvr.org', 'rubiconproject.com',
  'pubmatic.com', 'openx.net', 'casalemedia.com', 'indexww.com',
  'criteo.com', 'criteo.net', 'smartadserver.com', 'adform.net',
  'bidswitch.net', 'contextweb.com', 'lijit.com', 'sharethrough.com',
  'teads.tv', 'media.net', 'yieldmo.com', 'triplelift.com', 'gumgum.com',
  'moatads.com', 'adsafeprotected.com', 'scorecardresearch.com',
  'quantserve.com', 'quantcount.com', 'serving-sys.com', 'advertising.com',
  // native / recommendation ads
  'taboola.com', 'outbrain.com', 'revcontent.com', 'mgid.com',
  'zemanta.com', 'content-ad.net', 'nativeroll.tv',
  // pop-up / pop-under / redirect networks
  'popads.net', 'popcash.net', 'propellerads.com', 'propellerclick.com',
  'exoclick.com', 'exosrv.com', 'adsterra.com', 'adsterratools.com',
  'juicyads.com', 'trafficjunky.net', 'trafficfactory.biz',
  'clickadu.com', 'hilltopads.net', 'hilltopads.com', 'richpush.co',
  'pushhouse.io', 'evadav.com', 'adcash.com', 'a-ads.com', 'adskeeper.com',
  'adxpansion.com', 'monetag.com', 'onclickads.net', 'onclkds.com',
  'onclickmax.com', 'tsyndicate.com', 'bidvertiser.com', 'revenuehits.com',
  'adspyglass.com', 'ad-maven.com', 'admaven.com', 'mc.yandex.ru',
  'syndication.exdynsrv.com', 'ero-advertising.com', 'zeropark.com',
  'realsrv.com', 'acscdn.com', 'highperformanceformat.com',
  'highcpmgate.com', 'profitablegatecpm.com', 'cpmgate.com',
  'effectivegatecpm.com', 'displayvertising.com', 'ad.gt',
  // trackers
  'hotjar.com', 'mouseflow.com', 'crazyegg.com', 'segment.io',
  'mixpanel.com', 'amplitude.com', 'branch.io', 'adjust.com',
  'appsflyer.com', 'chartbeat.com', 'newrelic.com', 'bugsnag.com',
  'facebook.net', 'connect.facebook.net', 'ads-twitter.com',
  'analytics.twitter.com', 'ads.linkedin.com', 'snap.licdn.com',
  'ads.tiktok.com', 'analytics.tiktok.com', 'ct.pinterest.com',
  // more ad exchanges, video ads and push-notification spam
  'adition.com', 'adtech.com', 'adtechus.com', 'advertising.amazon.com',
  'appnexus.com', 'bluekai.com', 'demdex.net', 'everesttech.net',
  'exelator.com', 'eyeota.net', 'krxd.net', 'liadm.com', 'mathtag.com',
  'media6degrees.com', 'nexac.com', 'omtrdc.net', 'rlcdn.com',
  'rfihub.com', 'sitescout.com', 'spotxchange.com', 'springserve.com',
  'tapad.com', 'turn.com', 'undertone.com', 'videohub.tv', 'vidoomy.com',
  'yieldlab.net', 'zedo.com', 'adhigh.net', 'adkernel.com', 'adbrite.com',
  'admixer.net', 'bidtheatre.com', 'getpopunder.com', 'popmyads.com',
  'push-sdk.com', 'pushengage.com', 'onesignal-ads.com', 'notix.io',
  'pushwhy.com', 'webpushr-ads.com', 'clickaine.com', 'clickporn.com',
  'direct-click.net', 'dolohen.com', 'fpnpmcdn.net', 'ntvpforever.com',
  'oclasrv.com', 'pemsrv.com', 'playukinternet.com', 'tzegilo.com',
  'wpnrtnmrewunrtok.xyz', 'yllix.com', 'yuhuads.com', 'ziffstatic-ads.com',
];

bool _isAdHost(String host) {
  final h = host.toLowerCase();
  for (final d in _adDomains) {
    if (h == d || h.endsWith('.$d')) return true;
  }
  return false;
}

/// Request-blocking rules. Many hosts share one rule (the engine tests every
/// request against every rule, so fewer rules means a faster page).
final List<String> _adPatterns = [
  for (var i = 0; i < _adDomains.length; i += 40)
    r'^https?://([^/]*\.)?(' +
        _adDomains
            .skip(i)
            .take(40)
            .map((d) => d.replaceAll('.', r'\.'))
            .join('|') +
        r')(:\d+)?(/.*)?$',
  r'.*/(ads?|adserver|banners?)/[^/]*\.js(\?.*)?$',
  r'.*[/?&_.-](popunder|popundr|clickunder)[/?&_.-].*',
];

/// Empty ad boxes left on the page are hidden too.
const String _adHideSelectors = 'ins.adsbygoogle, .adsbygoogle, '
    '[id^="google_ads_iframe"], [id^="div-gpt-ad"], [id^="aswift_"], '
    'iframe[src*="doubleclick.net"], iframe[src*="googlesyndication.com"], '
    'iframe[src*="adsterra"], iframe[src*="exoclick"], '
    '.ad-banner, .ad-container, .ads-container, .advert, .advertisement, '
    '.sponsored-ad, #ad-banner, #ads, #adContainer, '
    // cookie / consent banners
    '#onetrust-banner-sdk, #onetrust-consent-sdk, .cookie-banner, '
    '.cookie-notice, #cookie-notice, #cookie-banner, .cc-window, '
    '.cookie-consent, [id*="cookie-consent"], [class*="cookie-consent"]';

/// Shortcuts that older versions added by themselves: removed from the start
/// page (only Google stays). Shortcuts the person added are never touched.
const _retiredShortcutUrls = {
  'https://www.wikipedia.org',
  'https://github.com',
  'https://www.reddit.com',
};

List<Shortcut> _withoutRetired(List<Shortcut> l) =>
    l.where((s) => !_retiredShortcutUrls.contains(s.url)).toList();

const List<Shortcut> _defaultShortcuts = [
  Shortcut('Google', 'https://www.google.com'),
];

/// Central state of the browser: tabs, settings, bookmarks and history.
class BrowserController extends ChangeNotifier {
  BrowserController._();
  static final BrowserController instance = BrowserController._();

  final List<BrowserTab> tabs = [];
  /// Addresses of recently closed tabs (newest last) for "Reopen Closed Tab".
  final List<String> closedUrls = [];
  int active = 0;

  bool blockAds = false;
  bool captureMedia = false;
  bool desktopMode = false;
  bool darkPages = false;
  bool dataSaver = false;
  bool httpsUpgrade = true;

  /// Hosts where https did not work: they stay on http.
  final Set<String> _noUpgrade = {};
  ThemeMode themeMode = ThemeMode.system;

  List<Shortcut> shortcuts = [];
  List<Shortcut> bookmarks = [];
  List<HistoryEntry> history = [];

  SharedPreferences? _prefs;
  int _idSeed = 0;

  BrowserTab get current {
    // there is always one tab, even if saved tabs could not be read
    if (tabs.isEmpty) {
      tabs.add(BrowserTab(id: _nextId()));
      active = 0;
    }
    return tabs[active.clamp(0, tabs.length - 1)];
  }

  // ---------------------------------------------------------------- init

  /// Pull-to-refresh on the browser start page: re-reads shortcuts and redraws.
  Future<void> refreshHome() async {
    final p = _prefs;
    if (p != null) {
      shortcuts = p.containsKey('b_shortcuts')
          ? _withoutRetired(_readList(p, 'b_shortcuts', Shortcut.fromJson))
          : [..._defaultShortcuts];
    }
    await Future.delayed(const Duration(milliseconds: 400));
    notifyListeners();
  }

  Future<void> init() async {
    final p = _prefs = await SharedPreferences.getInstance();
    blockAds = p.getBool('b_blockAds') ?? false;
    // capturing is on by default now (key renamed so old 'off' is not kept)
    captureMedia = p.getBool('b_capture2') ?? true;
    bubbleX = p.getDouble('b_bx') ?? 1.0;
    bubbleY = p.getDouble('b_by') ?? 0.72;
    desktopMode = p.getBool('b_desktop') ?? false;
    darkPages = p.getBool('b_darkPages') ?? false;
    dataSaver = p.getBool('b_dataSaver') ?? false;
    httpsUpgrade = p.getBool('b_httpsUp') ?? true;
    themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == p.getString('b_theme'),
      orElse: () => ThemeMode.system,
    );

    shortcuts = _withoutRetired(_readList(p, 'b_shortcuts', Shortcut.fromJson));
    if (!p.containsKey('b_shortcuts')) shortcuts = [..._defaultShortcuts];
    bookmarks = _readList(p, 'b_bookmarks', Shortcut.fromJson);
    history = _readList(p, 'b_history', HistoryEntry.fromJson);
    try {
      final raw = p.getString('b_icons');
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          _icons[k] = base64Decode(v as String);
        });
      }
    } catch (_) {}

    // restore tabs
    try {
      final raw = p.getString('b_tabs');
      if (raw != null) {
        for (final e in jsonDecode(raw) as List) {
          final m = e as Map<String, dynamic>;
          final url = (m['url'] as String?) ?? '';
          tabs.add(BrowserTab(
            id: _nextId(),
            url: url.isEmpty ? null : url,
            title: (m['title'] as String?) ?? '',
            showHome: (m['showHome'] as bool?) ?? url.isEmpty,
          ));
        }
        if (tabs.isNotEmpty) {
          active = (p.getInt('b_active') ?? 0).clamp(0, tabs.length - 1);
        }
      }
    } catch (_) {
      tabs.clear();
    }
    if (tabs.isEmpty) {
      tabs.add(BrowserTab(id: _nextId()));
      active = 0;
    }
  }

  List<T> _readList<T>(SharedPreferences p, String key,
      T Function(Map<String, dynamic>) f) {
    try {
      final raw = p.getString(key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => f(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  String _nextId() => '${DateTime.now().microsecondsSinceEpoch}_${_idSeed++}';

  // --------------------------------------------------------- persistence

  Future<void> save() async {
    final p = _prefs;
    if (p == null) return;
    await p.setBool('b_blockAds', blockAds);
    await p.setBool('b_capture2', captureMedia);
    await p.setBool('b_desktop', desktopMode);
    await p.setBool('b_darkPages', darkPages);
    await p.setBool('b_dataSaver', dataSaver);
    await p.setBool('b_httpsUp', httpsUpgrade);
    await p.setString('b_theme', themeMode.name);
    await p.setString(
        'b_shortcuts', jsonEncode(shortcuts.map((e) => e.toJson()).toList()));
    await p.setString(
        'b_bookmarks', jsonEncode(bookmarks.map((e) => e.toJson()).toList()));
    await _saveHistory();
    await _saveIcons();
    await saveTabs();
  }

  Future<void> _saveHistory() async => _prefs?.setString('b_history',
      jsonEncode(history.take(500).map((e) => e.toJson()).toList()));

  Future<void> _saveIcons() async => _prefs?.setString('b_icons',
      jsonEncode(_icons.map((k, v) => MapEntry(k, base64Encode(v)))));

  // A page load touches history and the site icon: write each of them once,
  // a moment later, instead of re-saving everything on every page.
  Timer? _historyTimer;
  Timer? _iconsTimer;

  void _saveHistoryLater() {
    _historyTimer?.cancel();
    _historyTimer = Timer(const Duration(seconds: 2), _saveHistory);
  }

  void _saveIconsLater() {
    _iconsTimer?.cancel();
    _iconsTimer = Timer(const Duration(seconds: 3), _saveIcons);
  }

  Future<void> saveTabs() async {
    final p = _prefs;
    if (p == null) return;
    await p.setString('b_tabs', jsonEncode(
        tabs.where((t) => !t.incognito).map((t) => t.toJson()).toList()));
    await p.setInt('b_active', active.clamp(0, tabs.length - 1));
  }

  // ---------------------------------------------------------------- tabs

  /// True while the browser screen is on the navigation stack.
  bool screenOpen = false;

  /// Whether the browser is the screen shown in the main window (the bottom
  /// bar of the main window stays visible either way).
  final ValueNotifier<bool> visible = ValueNotifier(false);

  /// Pauses every video / song on the page (and in same-site frames).
  static const pauseMediaJs = r'''
(function(){
  function stop(d){
    try{ d.querySelectorAll('video,audio').forEach(function(e){try{e.pause();}catch(x){}}); }catch(x){}
    try{ d.querySelectorAll('iframe').forEach(function(f){ try{ if(f.contentDocument) stop(f.contentDocument); }catch(x){} }); }catch(x){}
  }
  stop(document);
})();
''';

  void openScreen() => visible.value = true;
  void closeScreen() => visible.value = false;

  BrowserTab newTab(
      {String? url, int? windowId, bool activate = true, bool incognito = false}) {
    final t = BrowserTab(
      id: _nextId(),
      url: url,
      windowId: windowId,
      incognito: incognito,
      showHome: url == null && windowId == null,
    );
    if (url != null) t.wantsWebView = true;
    t.activated = true; // opened on purpose: load it now
    tabs.add(t);
    if (activate) active = tabs.length - 1;
    saveTabs();
    notifyListeners();
    return t;
  }

  void switchTo(int i) {
    if (i < 0 || i >= tabs.length || i == active) return;
    active = i;
    saveTabs();
    notifyListeners();
  }

  void closeTab(int i) {
    if (i < 0 || i >= tabs.length) return;
    final t = tabs.removeAt(i);
    if (!t.incognito && !t.showHome && t.url.startsWith('http')) {
      closedUrls.add(t.url);
      if (closedUrls.length > 10) closedUrls.removeAt(0);
    }
    if (tabs.isEmpty) {
      tabs.add(BrowserTab(id: _nextId()));
      active = 0;
    } else if (i < active) {
      active -= 1;
    } else if (active >= tabs.length) {
      active = tabs.length - 1;
    }
    if (t.incognito && !tabs.any((x) => x.incognito)) _forgetIncognito();
    // dispose after the frame so the WebView widget can be removed first
    WidgetsBinding.instance.addPostFrameCallback((_) => t.dispose());
    saveTabs();
    notifyListeners();
  }

  /// Opens the most recently closed tab again.
  void reopenClosedTab() {
    if (closedUrls.isEmpty) return;
    newTab(url: closedUrls.removeLast());
  }

  void closeTabById(String id) => closeTab(tabs.indexWhere((t) => t.id == id));

  /// The screen showing the WebViews is being destroyed.
  void detachAll() {
    for (final t in tabs) {
      t.detach();
    }
  }

  // ---------------------------------------------------------- navigation

  /// Turns whatever the user typed into a URL or a Google search.
  static String resolveInput(String input) {
    final t = input.trim();
    if (t.isEmpty) return t;
    final lower = t.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) return t;
    if (lower.startsWith('file://') || lower.startsWith('about:')) return t;
    final looksLikeHost = !t.contains(' ') &&
        (t.contains('.') || lower.startsWith('localhost')) &&
        !t.endsWith('.');
    if (looksLikeHost) {
      // local servers and IP addresses (router pages) are plain http
      final host = t.split(RegExp(r'[/:?#]')).first;
      final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
      return (isIp || lower.startsWith('localhost')) ? 'http://$t' : 'https://$t';
    }
    return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
  }

  Future<void> navigate(String input, {BrowserTab? tab}) async {
    final t = tab ?? current;
    var url = resolveInput(input);
    if (url.isEmpty) return;
    final up = upgradeUrl(url);
    if (up != null) {
      t.upgradedFrom = url;
      url = up;
    }
    t.error = null;
    t.setShowHome(false);
    final c = t.controller;
    if (c == null) {
      // WebView not created yet: it will be built with this URL
      t.pendingUrl = url;
      t.wantsWebView = true;
      t.setUrl(url);
    } else {
      t.setUrl(url);
      await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    }
    notifyListeners();
    saveTabs();
  }

  Future<void> goBack() async {
    final t = current;
    if (t.showHome && t.controller != null) {
      t.setShowHome(false); // return to the page hidden behind the homepage
      return;
    }
    if (await t.controller?.canGoBack() ?? false) {
      await t.controller!.goBack();
    }
  }

  Future<void> goForward() async {
    final t = current;
    if (t.showHome) return;
    if (await t.controller?.canGoForward() ?? false) {
      await t.controller!.goForward();
    }
  }

  void goHome() {
    current.setShowHome(true);
    notifyListeners();
    saveTabs();
  }

  Future<void> reload() async {
    final t = current;
    if (t.showHome) return;
    t.error = null;
    if (t.isLoading) {
      await t.controller?.stopLoading();
    } else {
      await t.controller?.reload();
    }
  }

  Future<void> refreshNavState(BrowserTab t) async {
    final c = t.controller;
    if (c == null) return;
    final b = await c.canGoBack();
    final f = await c.canGoForward();
    if (b != t.canGoBack || f != t.canGoForward) {
      t.update(() {
        t.canGoBack = b;
        t.canGoForward = f;
      });
    }
  }

  // ------------------------------------------------------------ settings

  InAppWebViewSettings webSettings({bool incognito = false}) => InAppWebViewSettings(
        // private tabs keep nothing on the phone
        cacheMode: incognito ? CacheMode.LOAD_NO_CACHE : CacheMode.LOAD_DEFAULT,
        saveFormData: !incognito,
        javaScriptEnabled: true,
        useOnDownloadStart: true,
        useShouldOverrideUrlLoading: true,
        useOnLoadResource: true,
        supportMultipleWindows: true,
        mediaPlaybackRequiresUserGesture: true,
        allowsInlineMediaPlayback: true,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        safeBrowsingEnabled: true,
        // pages served over https that load http images / scripts still show
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        thirdPartyCookiesEnabled: true,
        domStorageEnabled: true,
        blockNetworkImage: dataSaver,
        preferredContentMode: desktopMode
            ? UserPreferredContentMode.DESKTOP
            : UserPreferredContentMode.RECOMMENDED,
        // with ad blocking on, a page may not open windows by itself at all
        javaScriptCanOpenWindowsAutomatically: !blockAds,
        contentBlockers: blockAds
            ? [
                for (final p in _adPatterns)
                  ContentBlocker(
                    trigger: ContentBlockerTrigger(urlFilter: p),
                    action:
                        ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
                  ),
                ContentBlocker(
                  trigger: ContentBlockerTrigger(urlFilter: '.*'),
                  action: ContentBlockerAction(
                      type: ContentBlockerActionType.CSS_DISPLAY_NONE,
                      selector: _adHideSelectors),
                ),
              ]
            : [],
      );

  Future<void> _applySettings({bool reloadPages = false}) async {
    for (final t in tabs) {
      final c = t.controller;
      if (c == null) continue;
      try {
        await c.setSettings(settings: webSettings(incognito: t.incognito));
        if (reloadPages && !t.showHome) await c.reload();
      } catch (_) {}
    }
  }

  Future<void> setBlockAds(bool v) async {
    blockAds = v;
    notifyListeners();
    await _applySettings(reloadPages: true);
    await save();
  }

  /// Turns every page dark by inverting it; pictures and videos are turned
  /// back so they keep their real colours.
  static const darkOnJs = r'''
(function(){
  if(document.getElementById('__sdm_dark')) return;
  var s=document.createElement('style'); s.id='__sdm_dark';
  s.textContent='html{filter:invert(1) hue-rotate(180deg)!important;background:#fff}'
   +'img,video,picture,canvas,iframe,[style*="background-image"]{filter:invert(1) hue-rotate(180deg)!important}';
  (document.head||document.documentElement).appendChild(s);
})()
''';
  static const darkOffJs =
      "var e=document.getElementById('__sdm_dark'); if(e) e.remove();";

  Future<void> setDarkPages(bool v) async {
    darkPages = v;
    notifyListeners();
    for (final t in tabs) {
      try {
        await t.controller?.evaluateJavascript(source: v ? darkOnJs : darkOffJs);
      } catch (_) {}
    }
    await save();
  }

  Future<void> setDataSaver(bool v) async {
    dataSaver = v;
    notifyListeners();
    await _applySettings(reloadPages: true);
    await save();
  }

  Future<void> setHttpsUpgrade(bool v) async {
    httpsUpgrade = v;
    notifyListeners();
    await save();
  }

  // ------------------------------------------------------- https upgrade

  /// The https version of an http address, or null when it should stay as it
  /// is (switched off, not http, local network, or https failed there before).
  String? upgradeUrl(String url) {
    if (!httpsUpgrade || !url.startsWith('http://')) return null;
    final h = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (h.isEmpty || h == 'localhost' || h.endsWith('.local')) return null;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) || h.contains(':')) {
      return null;
    }
    if (_noUpgrade.contains(h)) return null;
    return 'https://${url.substring(7)}';
  }

  /// https did not load for this tab: go back to the plain http address.
  Future<bool> fallbackToHttp(BrowserTab t) async {
    final from = t.upgradedFrom;
    if (from == null) return false;
    t.upgradedFrom = null;
    final h = Uri.tryParse(from)?.host.toLowerCase() ?? '';
    if (h.isNotEmpty) _noUpgrade.add(h);
    t.error = null;
    t.setUrl(from);
    try {
      await t.controller?.loadUrl(urlRequest: URLRequest(url: WebUri(from)));
    } catch (_) {
      return false;
    }
    return true;
  }

  // ----------------------------------------------------------- incognito

  /// Sites first opened in a private tab: they had no cookies before, so
  /// their cookies are removed when the last private tab closes. (Android has
  /// one cookie jar for all tabs, so sites already signed in stay as they are.)
  final Set<String> _incoFresh = {};
  final Set<String> _incoSeen = {};

  Future<void> noteIncognitoPage(String url) async {
    final u = Uri.tryParse(url);
    if (u == null || !u.scheme.startsWith('http') || u.host.isEmpty) return;
    if (!_incoSeen.add(u.host)) return;
    try {
      final c = await CookieManager.instance().getCookies(url: WebUri(url));
      if (c.isEmpty) _incoFresh.add(u.host);
    } catch (_) {}
  }

  Future<void> _forgetIncognito() async {
    final hosts = _incoFresh.toList();
    _incoFresh.clear();
    _incoSeen.clear();
    final cm = CookieManager.instance();
    for (final h in hosts) {
      try {
        final url = WebUri('https://$h/');
        final list = await cm.getCookies(url: url);
        for (final c in list) {
          await cm.deleteCookie(
              url: url, name: c.name, domain: c.domain, path: c.path ?? '/');
        }
      } catch (_) {}
    }
  }

  // --------------------------------------------------------- reader mode

  /// Turns the open page into a clean reading view (title, text, pictures).
  /// Returns false when the page has no article to show.
  Future<bool> readerMode() async {
    final c = current.controller;
    if (c == null || current.showHome) return false;
    try {
      final r = await c.evaluateJavascript(source: readerJs);
      return r == true || r == 'true';
    } catch (_) {
      return false;
    }
  }

  static const readerJs = r'''
(function(){
  if (document.getElementById('sdm-reader')) return true;
  function score(e){
    var ps = e.querySelectorAll('p'), n = 0;
    for (var i=0;i<ps.length;i++){ var t=(ps[i].innerText||'').trim(); if (t.length>60) n += t.length; }
    return n;
  }
  var best=null, bs=0, mx=0, sc=[];
  var cands = document.querySelectorAll('article, main, [role=main], section, div');
  for (var i=0;i<cands.length;i++){ sc[i]=score(cands[i]); if(sc[i]>mx) mx=sc[i]; }
  // outer blocks come first in the page: the last one that still holds most
  // of the text is the innermost, i.e. the article itself
  for (var j=0;j<cands.length;j++){ if (sc[j]>=mx*0.85){best=cands[j];bs=sc[j];} }
  if(!best||bs<300) return false;
  var skip=/^(SCRIPT|STYLE|NAV|FOOTER|ASIDE|FORM|IFRAME|BUTTON|NOSCRIPT|SVG|HEADER)$/;
  var out=document.createElement('div');
  function walk(n){
    for (var k=n.firstChild;k;k=k.nextSibling){
      if (k.nodeType!==1) continue;
      var tg=k.tagName;
      if (skip.test(tg)) continue;
      if (/^(P|H1|H2|H3|H4|BLOCKQUOTE|UL|OL|PRE|FIGURE)$/.test(tg)){
        var t=(k.innerText||'').trim();
        if (!t && !k.querySelector('img')) continue;
        var c=k.cloneNode(true);
        c.querySelectorAll('script,style,iframe,button,form,svg').forEach(function(x){x.remove();});
        c.removeAttribute('style'); c.removeAttribute('class'); c.removeAttribute('id');
        out.appendChild(c);
      } else if (tg==='IMG'){
        var src=k.currentSrc||k.src; if(src&&(k.naturalWidth||k.width)>120){var im=document.createElement('img');im.src=src;out.appendChild(im);}
      } else walk(k);
    }
  }
  walk(best);
  if (out.innerText.trim().length<200) return false;
  var title=(document.title||'').trim();
  var h1=document.querySelector('h1'); if(h1&&h1.innerText.trim().length>5) title=h1.innerText.trim();
  var themes=[['#ffffff','#1a1a1a','#2563eb'],['#f4ecd8','#3b2f1e','#9a5b13'],['#121212','#d8d8d8','#7fb2ff']];
  var ti=0, fs=19;
  var root=document.createElement('div'); root.id='sdm-reader';
  var st=document.createElement('style');
  function css(){
    var t=themes[ti];
    st.textContent='html,body{margin:0!important;padding:0!important;background:'+t[0]+'!important}'+
    '#sdm-reader{position:absolute;left:0;top:0;width:100%;min-height:100%;box-sizing:border-box;background:'+t[0]+';color:'+t[1]+';z-index:2147483647;padding:0 0 60px;font-family:Georgia,serif}'+
    '#sdm-reader .bar{position:sticky;top:0;display:flex;gap:8px;justify-content:flex-end;padding:8px 12px;background:'+t[0]+';border-bottom:1px solid '+t[1]+'22}'+
    '#sdm-reader .bar button{font:600 15px sans-serif;border:1px solid '+t[1]+'44;background:transparent;color:'+t[1]+';border-radius:10px;padding:6px 12px}'+
    '#sdm-reader .body{max-width:720px;margin:0 auto;padding:12px 18px;font-size:'+fs+'px;line-height:1.7;word-wrap:break-word}'+
    '#sdm-reader h1{font-size:1.5em;line-height:1.25;margin:.6em 0}'+
    '#sdm-reader h2,#sdm-reader h3{line-height:1.3}'+
    '#sdm-reader img{max-width:100%;height:auto;border-radius:8px;margin:.5em 0;display:block}'+
    '#sdm-reader a{color:'+t[2]+'}'+
    '#sdm-reader blockquote{border-left:3px solid '+t[2]+';margin:1em 0;padding-left:14px;opacity:.85}'+
    '#sdm-reader pre{overflow:auto;background:'+t[1]+'14;padding:10px;border-radius:8px}';
  }
  function btn(l,f){var b=document.createElement('button');b.textContent=l;b.onclick=f;return b;}
  var bar=document.createElement('div'); bar.className='bar';
  bar.appendChild(btn('A−',function(){fs=Math.max(13,fs-2);css();}));
  bar.appendChild(btn('A+',function(){fs=Math.min(34,fs+2);css();}));
  bar.appendChild(btn('◐',function(){ti=(ti+1)%themes.length;css();}));
  bar.appendChild(btn('✕',function(){location.reload();}));
  var body=document.createElement('div'); body.className='body';
  var h=document.createElement('h1'); h.textContent=title; body.appendChild(h);
  body.appendChild(out);
  root.appendChild(st); root.appendChild(bar); root.appendChild(body);
  css();
  document.body.appendChild(root);
  window.scrollTo(0,0);
  return true;
})()
''';

  Future<void> setDesktopMode(bool v) async {
    desktopMode = v;
    notifyListeners();
    await _applySettings(reloadPages: true);
    await save();
  }

  Future<void> setCaptureMedia(bool v) async {
    captureMedia = v;
    if (!v) {
      for (final t in tabs) {
        t.media.clear();
      }
    }
    notifyListeners();
    await save();
  }

  Future<void> setThemeMode(ThemeMode m) async {
    themeMode = m;
    notifyListeners();
    await save();
  }

  // ----------------------------------------------------------- bookmarks

  bool isBookmarked(String url) => bookmarks.any((b) => b.url == url);

  Future<void> toggleBookmark(BrowserTab t) async {
    if (t.url.isEmpty) return;
    if (isBookmarked(t.url)) {
      bookmarks.removeWhere((b) => b.url == t.url);
    } else {
      bookmarks.insert(
          0, Shortcut(t.title.isNotEmpty ? t.title : t.host, t.url));
    }
    notifyListeners();
    await save();
  }

  Future<void> removeBookmark(Shortcut b) async {
    bookmarks.removeWhere((e) => e.url == b.url);
    notifyListeners();
    await save();
  }

  // ------------------------------------------------------------- history

  /// Page icons (favicons) by site, so History can show them later.
  final Map<String, Uint8List> _icons = {};

  Uint8List? iconFor(String url) {
    final h = Uri.tryParse(url)?.host ?? '';
    return _icons[h];
  }

  final Set<String> _iconTried = {};
  final Dio _iconDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 6),
    responseType: ResponseType.bytes,
    headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 13) SDM'},
  ));

  /// Fetches the logo of a site when none is known yet (used by shortcuts).
  Future<void> ensureIcon(String url) async {
    final u = Uri.tryParse(url.startsWith('http') ? url : 'https://$url');
    final h = u?.host ?? '';
    if (h.isEmpty || iconFor('https://$h') != null || !_iconTried.add(h)) return;
    for (final src in [
      'https://www.google.com/s2/favicons?domain=$h&sz=128',
      'https://$h/favicon.ico',
    ]) {
      try {
        final r = await _iconDio.get<List<int>>(src);
        final data = r.data;
        if (data != null && data.length > 120 && data.length <= 24000) {
          rememberIcon('https://$h', Uint8List.fromList(data));
          return;
        }
      } catch (_) {}
    }
  }

  void rememberIcon(String url, Uint8List? icon) {
    final h = Uri.tryParse(url)?.host ?? '';
    if (h.isEmpty || icon == null || icon.isEmpty || icon.length > 24000) {
      return;
    }
    final old = _icons[h];
    if (old != null && old.length == icon.length) return;
    _icons.remove(h);
    _icons[h] = icon;
    while (_icons.length > 100) {
      _icons.remove(_icons.keys.first);
    }
    notifyListeners();
    _saveIconsLater();
  }

  void addHistory(BrowserTab t) {
    if (t.incognito) return;
    final u = t.url;
    if (u.isEmpty || !(u.startsWith('http://') || u.startsWith('https://'))) {
      return;
    }
    rememberIcon(u, t.favicon);
    if (history.isNotEmpty && history.first.url == u) return;
    history.insert(
        0,
        HistoryEntry(t.title.isNotEmpty ? t.title : t.host, u,
            DateTime.now().millisecondsSinceEpoch));
    if (history.length > 500) history.removeRange(500, history.length);
    _saveHistoryLater();
  }

  Future<void> removeHistory(Iterable<HistoryEntry> list) async {
    final drop = list.toSet();
    history.removeWhere(drop.contains);
    notifyListeners();
    await save();
  }

  Future<void> clearHistory() async {
    history.clear();
    notifyListeners();
    await save();
  }

  // ----------------------------------------------------------- shortcuts

  Future<void> addShortcut(String name, String url) async {
    final u = resolveInput(url);
    final n = name.trim().isEmpty ? (Uri.tryParse(u)?.host ?? u) : name.trim();
    shortcuts.add(Shortcut(n, u));
    notifyListeners();
    await save();
    ensureIcon(u);
  }

  Future<void> removeShortcut(Shortcut s) async {
    shortcuts.remove(s);
    notifyListeners();
    await save();
  }

  // -------------------------------------------------------- clear data

  Future<void> clearBrowsingData(
      {bool history = true, bool cache = true, bool cookies = true}) async {
    if (cache) {
      try {
        await InAppWebViewController.clearAllCache();
      } catch (_) {}
    }
    if (cookies) {
      try {
        await CookieManager.instance().deleteAllCookies();
      } catch (_) {}
      try {
        await WebStorageManager.instance().deleteAllData();
      } catch (_) {}
    }
    if (history) this.history.clear();
    notifyListeners();
    await save();
  }

  // -------------------------------------------------------------- media

  static const _audioExt = {
    'mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac', 'opus', 'weba', 'mka'
  };
  static const _videoExt = {
    'mp4', 'webm', 'mkv', 'mov', '3gp', 'm4v', 'flv', 'avi', 'mpg', 'mpeg'
  };

  /// True when [host] belongs to an ad / tracker / pop-up network.
  bool isAdHost(String host) => _isAdHost(host);

  static String _extOf(String url) {
    final u = Uri.tryParse(url);
    final last = (u != null && u.pathSegments.isNotEmpty) ? u.pathSegments.last : '';
    return last.contains('.') ? last.split('.').last.toLowerCase() : '';
  }

  /// Direct media files and HLS streams. YouTube and similar are skipped.
  bool isCapturableMedia(String url, {bool fromMediaElement = false}) {
    final u = Uri.tryParse(url);
    if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) {
      return false;
    }
    final h = u.host.toLowerCase();
    if (h.endsWith('googlevideo.com') ||
        h.endsWith('youtube.com') ||
        h.endsWith('youtu.be')) {
      return false;
    }
    if (blockAds && _isAdHost(h)) return false; // ad videos are no downloads
    final ext = _extOf(url);
    if (ext == 'mpd') return false; // DASH is not supported
    return ext == 'm3u8' ||
        _audioExt.contains(ext) ||
        _videoExt.contains(ext) ||
        fromMediaElement;
  }

  Future<String?> _userAgentOf(BrowserTab t) async {
    if (t.userAgent != null) return t.userAgent;
    try {
      final r = await t.controller?.evaluateJavascript(source: 'navigator.userAgent');
      if (r is String && r.isNotEmpty) t.userAgent = r;
    } catch (_) {}
    return t.userAgent;
  }

  /// Headers a site expects for its media (page as referer, cookies).
  Future<Map<String, String>> pageHeaders(BrowserTab t, String url) async {
    final h = <String, String>{};
    if (t.url.startsWith('http')) h['Referer'] = t.url;
    // streams are often only handed to the browser they were opened in
    final ua = await _userAgentOf(t);
    if (ua != null && ua.isNotEmpty) h['User-Agent'] = ua;
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      if (cookies.isNotEmpty) {
        h['Cookie'] = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      }
    } catch (_) {}
    return h;
  }

  /// A media URL was seen on [t]. [element] = 'video' / 'audio' when it comes
  /// from a player on the page; [height] is the picture height if known.
  void addMedia(BrowserTab t, String url,
      {String? element,
      int height = 0,
      String label = '',
      bool hls = false}) {
    if (!captureMedia) return;
    if (!isCapturableMedia(url, fromMediaElement: element != null)) return;
    final ext = _extOf(url);
    // the same file often comes back with a new token in the address:
    // keep one entry (host + path) and refresh its address
    final key = _mediaKey(url);
    final idx = t.media.indexWhere((e) => _mediaKey(e.url) == key);
    if (idx >= 0) {
      final existing = t.media[idx];
      var changed = false;
      if (height > 0 && existing.height == 0) {
        existing.height = height;
        changed = true;
      }
      if (existing.url != url && !existing.hls) {
        t.media[idx] = MediaEntry(url,
            audio: existing.audio,
            height: existing.height,
            bandwidth: existing.bandwidth,
            size: existing.size,
            label: existing.label);
        changed = true;
      }
      if (changed) t.update(() {});
      return;
    }
    if (ext == 'm3u8' || hls) {
      _addHls(t, url);
      return;
    }
    final audio = element == 'audio' || _audioExt.contains(ext);
    t.media.add(MediaEntry(url, audio: audio, height: height, label: label));
    // pages that load many small pieces must not grow the list without end
    if (t.media.length > 80) t.media.removeRange(0, t.media.length - 80);
    t.update(() {});
  }

  static String _mediaKey(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return url;
    return '${u.host}${u.path}';
  }

  Future<void> _addHls(BrowserTab t, String url) async {
    // reserve the URL so it is looked at only once
    final marker = MediaEntry(url, hls: true, live: true);
    t.media.add(marker);
    try {
      final dm = DownloadManager.instance;
      final headers = await pageHeaders(t, url);
      // the player may sit in a frame of another site: if the page address is
      // refused as Referer, try the stream's own site, then none
      final origin = Uri.parse(url).origin;
      final tries = <Map<String, String>>[
        headers,
        {...headers, 'Referer': '$origin/', 'Origin': origin},
        {...headers}..remove('Referer'),
      ];
      String? text;
      String? okReferer; // '' = none
      Object? lastError;
      for (final h in tries) {
        try {
          text = await dm.fetchText(url, headers: h);
          if (text.contains('#EXTM3U')) {
            okReferer = h['Referer'] ?? '';
            break;
          }
          text = null;
        } catch (e) {
          lastError = e;
        }
      }
      if (text == null) throw lastError ?? 'not a playlist';
      final base = Uri.parse(url);
      t.media.remove(marker);
      if (isMasterPlaylist(text)) {
        final m = parseMaster(text, base);
        for (final v in m.variants) {
          if (t.media.any((e) => e.url == v.url.toString())) continue;
          t.media.add(MediaEntry(v.url.toString(),
              hls: true,
              referer: okReferer,
              height: v.height,
              bandwidth: v.bandwidth,
              separateAudio: v.separateAudio));
        }
        for (final a in m.audios) {
          if (t.media.any((e) => e.url == a.url.toString())) continue;
          t.media.add(MediaEntry(a.url.toString(),
              hls: true, audio: true, label: a.name, referer: okReferer));
        }
      } else {
        final m = parseMedia(text, base);
        if (m.segments.isEmpty) {
          t.update(() {});
          return;
        }
        t.media.add(MediaEntry(url,
            hls: true,
            referer: okReferer,
            seconds: m.seconds,
            encrypted: m.encrypted,
            live: m.live,
            audio: m.init == null &&
                (m.segments.first.path.toLowerCase().endsWith('.aac') ||
                    m.segments.first.path.toLowerCase().endsWith('.mp3'))));
      }
    } catch (_) {
      t.media.remove(marker);
    }
    t.update(() {});
  }

  // --- floating media button: where the user left it (0..1 of the page area)
  double bubbleX = 1.0;
  double bubbleY = 0.72;

  Future<void> setBubble(double x, double y) async {
    bubbleX = x.clamp(0.0, 1.0);
    bubbleY = y.clamp(0.0, 1.0);
    try {
      final p = _prefs;
      await p?.setDouble('b_bx', bubbleX);
      await p?.setDouble('b_by', bubbleY);
    } catch (_) {}
  }
}
