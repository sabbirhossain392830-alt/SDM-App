import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_controller.dart';
import 'browser_tab.dart';
import 'download_prompt.dart';
import 'home_page.dart';
import 'link_menu.dart';
import 'page_dialogs.dart';
import '../l10n.dart';

/// Renders one tab: its WebView (kept alive underneath), the homepage overlay
/// and the error page.
class TabView extends StatelessWidget {
  final BrowserTab tab;
  final BrowserController browser;
  final void Function(DownloadRequest) onDownload;

  const TabView({
    super.key,
    required this.tab,
    required this.browser,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tab,
      builder: (context, _) {
        return Stack(
          children: [
            if (tab.hasWebView && tab.activated)
              Positioned.fill(
                child: _WebHost(
                  key: ValueKey('host_${tab.id}'),
                  tab: tab,
                  browser: browser,
                  onDownload: onDownload,
                ),
              ),
            if (tab.error != null && !tab.showHome)
              Positioned.fill(child: _ErrorView(tab: tab, browser: browser)),
            if (tab.showHome) Positioned.fill(child: HomePage(browser: browser)),
          ],
        );
      },
    );
  }
}

/// Creates the InAppWebView exactly once per tab, so rebuilding the UI (drawer,
/// menu, toolbar) never recreates the WebView or loses the page.
class _WebHost extends StatefulWidget {
  final BrowserTab tab;
  final BrowserController browser;
  final void Function(DownloadRequest) onDownload;

  const _WebHost({
    super.key,
    required this.tab,
    required this.browser,
    required this.onDownload,
  });

  @override
  State<_WebHost> createState() => _WebHostState();
}

class _WebHostState extends State<_WebHost> {
  late final Widget _web;
  late final PullToRefreshController _pull;

  BrowserTab get tab => widget.tab;
  BrowserController get browser => widget.browser;

  static const _fileExt = {
    'zip', 'rar', '7z', 'tar', 'gz', 'iso', 'apk', 'pdf', 'exe', 'msi', 'dmg',
    'torrent', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'epub', 'mp3',
    'm4a', 'aac', 'wav', 'flac', 'ogg', 'mp4', 'mkv', 'webm', 'avi', 'mov',
    '3gp',
  };

  bool _looksLikeFile(Uri u) {
    if (u.pathSegments.isEmpty) return false;
    final last = u.pathSegments.last;
    if (!last.contains('.')) return false;
    return _fileExt.contains(last.split('.').last.toLowerCase());
  }

  @override
  void initState() {
    super.initState();

    tab.findController = FindInteractionController(
      onFindResultReceived:
          (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        tab.update(() {
          tab.findActive = activeMatchOrdinal;
          tab.findTotal = numberOfMatches;
        });
      },
    );

    final usePopupWindow = tab.windowId != null;

    // Pull the page down to reload it, like Chrome.
    _pull = PullToRefreshController(
      settings: PullToRefreshSettings(
        color: const Color(0xFF3B82F6),
        backgroundColor: Colors.white,
      ),
      onRefresh: () async {
        final c = tab.controller;
        if (c == null) {
          await _pull.endRefreshing();
          return;
        }
        tab.update(() => tab.error = null);
        await c.reload();
      },
    );

    _web = InAppWebView(
      key: ValueKey('wv_${tab.id}'),
      windowId: tab.windowId,
      pullToRefreshController: _pull,
      initialUrlRequest: (!usePopupWindow && tab.pendingUrl != null)
          ? URLRequest(url: WebUri(tab.pendingUrl!))
          : null,
      initialSettings: browser.webSettings(),
      findInteractionController: tab.findController,
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _hookJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          // players inside iframes are found too
          forMainFrameOnly: false,
        ),
      ]),
      onWebViewCreated: (c) {
        tab.controller = c;
        c.addJavaScriptHandler(
          handlerName: 'drom_media',
          callback: (args) {
            if (browser.captureMedia && args.isNotEmpty) _takeMedia(args.first);
            return null;
          },
        );
      },
      onLoadStart: (c, url) {
        if (browser.darkPages) c.evaluateJavascript(source: BrowserController.darkOnJs);
        if (url != null) tab.setUrl(url.toString());
        tab.update(() {
          tab.isLoading = true;
          tab.progress = 5;
          tab.error = null;
          tab.resources.clear();
          tab.media.clear();
        });
      },
      onProgressChanged: (c, p) {
        // Each update rebuilds the toolbar and tab views: do it in steps,
        // not for every single percent, so scrolling and loading stay smooth.
        if (p >= 100 || p < tab.progress || p - tab.progress >= 8) {
          tab.update(() {
            tab.progress = p;
            tab.isLoading = p < 100;
          });
        }
      },
      onUpdateVisitedHistory: (c, url, isReload) {
        if (url != null) tab.setUrl(url.toString());
        browser.refreshNavState(tab);
      },
      onTitleChanged: (c, title) {
        if (title != null) tab.setTitle(title);
      },
      onReceivedIcon: (c, Uint8List icon) {
        tab.update(() => tab.favicon = icon);
        browser.rememberIcon(tab.url, icon);
      },
      onLoadStop: (c, url) async {
        if (browser.darkPages) c.evaluateJavascript(source: BrowserController.darkOnJs);
        if (url != null) tab.setUrl(url.toString());
        final title = await c.getTitle();
        if (title != null && title.isNotEmpty) tab.setTitle(title);
        tab.update(() {
          tab.isLoading = false;
          tab.progress = 100;
        });
        _pull.endRefreshing();
        await browser.refreshNavState(tab);
        browser.addHistory(tab);
        browser.saveTabs();
        if (browser.captureMedia) {
          _scanMedia(c);
          _scanLater(c);
        }
      },
      onReceivedError: (c, request, error) {
        if (!(request.isForMainFrame ?? false)) return;
        _pull.endRefreshing();
        final d = error.description;
        if (d.contains('ERR_ABORTED')) return; // e.g. a download took over
        tab.update(() {
          tab.error = d.isEmpty ? 'The page could not be loaded' : d;
          tab.isLoading = false;
        });
      },
      onDownloadStartRequest: (c, req) {
        widget.onDownload(DownloadRequest(
          url: req.url.toString(),
          fileName: req.suggestedFilename,
          mimeType: req.mimeType,
          size: req.contentLength > 0 ? req.contentLength : null,
          userAgent: req.userAgent,
          referer: tab.url,
        ));
      },
      shouldOverrideUrlLoading: (c, action) async {
        final u = action.request.url;
        if (u == null) return NavigationActionPolicy.ALLOW;
        final scheme = u.scheme;
        if (scheme == 'http' || scheme == 'https') {
          final uri = Uri.tryParse(u.toString());
          // an ad network trying to take over the tab: stopped
          if (browser.blockAds &&
              action.isForMainFrame &&
              uri != null &&
              action.hasGesture != true &&
              browser.isAdHost(uri.host)) {
            return NavigationActionPolicy.CANCEL;
          }
          if ((action.isForMainFrame) && uri != null && _looksLikeFile(uri)) {
            widget.onDownload(DownloadRequest(
              url: u.toString(),
              userAgent: null,
              referer: tab.url,
            ));
            return NavigationActionPolicy.CANCEL;
          }
          return NavigationActionPolicy.ALLOW;
        }
        const ok = {'about', 'data', 'blob', 'javascript', 'file'};
        return ok.contains(scheme)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onCreateWindow: (c, action) async {
        // a page that opens windows by itself (ad pop-ups) gets none; links the
        // person taps (target=_blank) still open in a new tab
        if (action.hasGesture == false) return false;
        browser.newTab(windowId: action.windowId);
        return true;
      },
      onCloseWindow: (c) => browser.closeTabById(tab.id),
      onJsAlert: (c, r) async =>
          mounted ? pageAlert(context, r) : null,
      onJsConfirm: (c, r) async =>
          mounted ? pageConfirm(context, r) : null,
      onJsPrompt: (c, r) async =>
          mounted ? pagePrompt(context, r) : null,
      onPermissionRequest: (c, r) async => mounted
          ? pagePermission(context, r)
          : PermissionResponse(
              resources: r.resources, action: PermissionResponseAction.DENY),
      onGeolocationPermissionsShowPrompt: (c, origin) async => mounted
          ? pageLocation(context, origin)
          : GeolocationPermissionShowPromptResponse(
              origin: origin, allow: false, retain: false),
      onReceivedServerTrustAuthRequest: (c, ch) async =>
          mounted ? pageSslError(context, ch) : null,
      // a video taken full screen turns the phone sideways, like Chrome
      onEnterFullscreen: (c) => SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
      onExitFullscreen: (c) =>
          SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      onReceivedHttpAuthRequest: (c, ch) async =>
          mounted ? pageLogin(context, ch) : null,
      onLongPressHitTestResult: (c, hit) {
        final type = hit.type;
        final extra = hit.extra ?? '';
        final isImage = type == InAppWebViewHitTestResultType.IMAGE_TYPE;
        final isLink = type == InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE ||
            type == InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE;
        if (!(isImage || isLink) || !mounted) return;
        final lower = extra.toLowerCase();
        if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
          return;
        }
        showLinkMenu(
          context,
          browser: browser,
          url: extra,
          isImage: isImage,
          referer: tab.url,
          onDownload: widget.onDownload,
        );
      },
      onLoadResource: (c, r) {
        final url = r.url?.toString();
        if (url == null || url.startsWith('data:')) return;
        tab.addResource(url, r.initiatorType ?? 'resource');
        if (browser.captureMedia && browser.isCapturableMedia(url)) {
          browser.addMedia(tab, url);
        }
      },
    );
  }

  // Reads every <video>/<audio> (and their <source> tags) on the page, with
  // the picture height when the page tells it.
  static const _scanJs = '''
(function(){
  var out=[];
  function num(x){var n=parseInt((x||'').toString().replace(/[^0-9]/g,''));return n>0&&n<10000?n:0;}
  document.querySelectorAll('video,audio').forEach(function(e){
    var k=e.tagName.toLowerCase();
    var s=e.currentSrc||e.src;
    if(s) out.push({u:s,k:k,h:e.videoHeight||0});
    e.querySelectorAll('source').forEach(function(x){
      if(x.src) out.push({u:x.src,k:k,h:num(x.getAttribute('size')||x.getAttribute('res')||x.getAttribute('data-res')||x.getAttribute('label')||x.getAttribute('title'))});
    });
  });
  return out;
})()
''';

  // Tells Flutter as soon as a player starts, so the media button shows up
  // at once (not only after the page finished loading).
  static const _hookJs = '''
(function(){
  if(window.__dromHook) return; window.__dromHook=true;
  function send(e){
    try{
      var v=e.target; if(!v||!v.tagName) return;
      var k=v.tagName.toLowerCase(); if(k!=='video'&&k!=='audio') return;
      var s=v.currentSrc||v.src; if(!s) return;
      window.flutter_inappwebview.callHandler('drom_media',{u:s,k:k,h:v.videoHeight||0});
    }catch(x){}
  }
  ['play','playing','loadedmetadata','loadeddata'].forEach(function(n){
    document.addEventListener(n,send,true);
  });
  // players that fetch their stream by script (HLS / mp4 / audio): report the
  // address as soon as the request is made
  var re=/\\.(m3u8|mp4|webm|mkv|m4v|mov|flv|mp3|m4a|aac|ogg|opus|wav|flac)(\\?|#|\$)/i;
  function seen(u){
    try{
      if(!u||typeof u!=='string') return;
      var a=new URL(u,location.href).href;
      if(!re.test(a)) return;
      var m=a.match(/\\.(mp3|m4a|aac|ogg|opus|wav|flac)(\\?|#|\$)/i);
      window.flutter_inappwebview.callHandler('drom_media',{u:a,k:m?'audio':'video',h:0});
    }catch(x){}
  }
  // streams whose address has no .mp4/.mp3 ending: the server's answer
  // (Content-Type video/* or audio/*) tells what it is
  var ctN=0;
  function byType(ct,u){
    try{
      if(!ct||!u||ctN>=12) return;
      ct=String(ct).toLowerCase();
      var a=new URL(u,location.href).href;
      if(/\\.(m4s|ts|cmfv|cmfa|aac|vtt|srt|jpg|png|webp|gif)(\\?|#|\$)/i.test(a)) return;
      if(/mp2t|segment|mp4-dash/.test(ct)) return;
      var aud=/^audio\//.test(ct);
      if(aud||/^video\//.test(ct)||/mpegurl/.test(ct)){
        ctN++;
        window.flutter_inappwebview.callHandler('drom_media',{u:a,k:aud?'audio':'video',h:0});
      }
    }catch(x){}
  }
  // an HLS playlist is recognised by its first line, whatever its address
  var plN=0;
  function byBody(rt,txt,u){
    try{
      if(plN>=12||!u) return;
      if(rt!==''&&rt!=='text') return;
      if(!txt||String(txt).slice(0,7)!=='#EXTM3U') return;
      plN++;
      var a=new URL(u,location.href).href;
      window.flutter_inappwebview.callHandler('drom_media',{u:a,k:'video',h:0,hls:true});
    }catch(x){}
  }
  try{
    var xo=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(m,u){
      seen(u);
      var self=this, uu=u;
      try{
        this.addEventListener('readystatechange',function(){
          if(self.readyState===2) byType(self.getResponseHeader('content-type'),uu);
          if(self.readyState===4&&(self.responseType===''||self.responseType==='text')) byBody('text',self.responseText,uu);
        });
      }catch(x){}
      return xo.apply(this,arguments);
    };
    var fo=window.fetch;
    if(fo) window.fetch=function(r){
      var u=null;
      try{u=(typeof r==='string')?r:(r&&r.url); seen(u);}catch(x){}
      var p=fo.apply(this,arguments);
      try{
        return p.then(function(resp){
          try{byType(resp.headers.get('content-type'),resp.url||u);}catch(x){}
          try{
            var cl=parseInt(resp.headers.get('content-length')||'0');
            var ct=(resp.headers.get('content-type')||'').toLowerCase();
            if(cl>0&&cl<300000&&!/^(image|video|audio)\//.test(ct)){
              var ru=resp.url||u;
              resp.clone().text().then(function(t){byBody('text',t,ru);}).catch(function(){});
            }
          }catch(x){}
          return resp;
        });
      }catch(x){return p;}
    };
  }catch(x){}
})();
''';

  void _takeMedia(dynamic e) {
    if (e is! Map) return;
    final u = e['u'];
    if (u is! String || u.isEmpty) return;
    final k = e['k'] == 'audio' ? 'audio' : 'video';
    final h = (e['h'] is num) ? (e['h'] as num).toInt() : 0;
    browser.addMedia(tab, u, element: k, height: h, hls: e['hls'] == true);
  }

  Future<void> _scanMedia(InAppWebViewController c) async {
    try {
      final res = await c.evaluateJavascript(source: _scanJs);
      if (res is List) {
        for (final e in res) {
          _takeMedia(e);
        }
      }
    } catch (_) {}
  }

  /// Players often start late: look again a few times after the page loads.
  void _scanLater(InAppWebViewController c) {
    for (final s in const [1, 3, 8, 16]) {
      Future.delayed(Duration(seconds: s), () {
        if (mounted && browser.captureMedia && tab.controller == c) {
          _scanMedia(c);
        }
      });
    }
  }

  @override
  void dispose() {
    tab.controller = null;
    try {
      tab.findController?.dispose();
    } catch (_) {}
    tab.findController = null;
    try {
      _pull.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _web;
}

class _ErrorView extends StatelessWidget {
  final BrowserTab tab;
  final BrowserController browser;
  const _ErrorView({required this.tab, required this.browser});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded, size: 56, color: cs.outline),
          const SizedBox(height: 16),
          const T("Can't open this page",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(tab.error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          Text(tab.url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 12)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () {
              tab.update(() => tab.error = null);
              tab.controller?.reload();
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const T('Try again'),
          ),
        ],
      ),
    );
  }
}
