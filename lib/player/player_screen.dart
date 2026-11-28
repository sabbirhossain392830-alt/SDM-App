import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import '../l10n.dart';
import '../link_intake.dart' show rootNavigatorKey;
import '../open_file.dart' show openExternal;
import 'subtitles.dart';

const _chan = MethodChannel('drom/player');

const _videoExts = {
  'mp4', 'm4v', 'mkv', 'webm', 'avi', 'mov', '3gp', 'ts', 'flv', 'mpg', 'mpeg',
};
const _audioExts = {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'};

String _ext(String p) {
  final d = p.lastIndexOf('.');
  return d < 0 ? '' : p.substring(d + 1).toLowerCase();
}

bool isPlayable(String path) =>
    _videoExts.contains(_ext(path)) || _audioExts.contains(_ext(path));

String _name(String p) => p.substring(p.lastIndexOf('/') + 1);

/// Opens SDM's own player for [path] (with the other videos of its folder as
/// the playlist).
Future<void> playInSdm(String path) async {
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  await nav.push<void>(PageRouteBuilder(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => PlayerScreen(path: path),
    transitionsBuilder: (_, a, __, child) =>
        FadeTransition(opacity: a, child: child),
  ));
}

String _fmt(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(x)}' : '${two(m)}:${two(x)}';
}

int _natural(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final y = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final n1 = int.tryParse(x[i]), n2 = int.tryParse(y[i]);
    final c = (n1 != null && n2 != null)
        ? n1.compareTo(n2)
        : x[i].compareTo(y[i]);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

class PlayerScreen extends StatefulWidget {
  final String path;
  const PlayerScreen({super.key, required this.path});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

enum _Panel { audio, sub }

class _Hud {
  final IconData icon;
  final String text;
  const _Hud(this.icon, this.text);
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  List<String> _list = [];
  int _i = 0;
  VideoPlayerController? _c;
  SharedPreferences? _prefs;
  String? _err;
  bool _ui = true;
  bool _locked = false;
  bool _pip = false;
  bool _landscape = true;
  bool _ended = false;
  double _speed = 1;
  BoxFit _fit = BoxFit.contain;
  List<SubCue> _cues = const [];
  bool _subsOn = true;
  _Panel? _panel;
  String? _subFile;
  int _subOffsetMs = 0;
  double? _dragV; // seek bar being dragged (ms)
  Timer? _hideT, _saveT, _hudT;
  final ValueNotifier<_Hud?> _hud = ValueNotifier(null);
  double _bright = 0.5, _vol = 0.5;
  double _seekStartMs = 0, _seekTargetMs = 0;
  double _dragDx = 0;
  bool _seeking = false;
  int _loadId = 0;

  bool get _isAudio => _audioExts.contains(_ext(_list.isEmpty ? widget.path : _list[_i]));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _chan.setMethodCallHandler((call) async {
      if (call.method == 'pip' && mounted) {
        setState(() {
          _pip = call.arguments == true;
          if (!_pip) _ui = true;
        });
      }
    });
    _init();
  }

  Future<void> _init() async {
    _prefs = await SharedPreferences.getInstance();
    _list = _siblings(widget.path);
    _i = _list.indexOf(widget.path);
    if (_i < 0) {
      _list = [widget.path];
      _i = 0;
    }
    try {
      _bright = ((await _chan.invokeMethod<double>('getBrightness')) ?? 0.5)
          .clamp(0.02, 1.0);
      _vol = ((await _chan.invokeMethod<double>('getVolume')) ?? 0.5)
          .clamp(0.0, 1.0);
    } catch (_) {}
    await _load(_i);
    _saveT = Timer.periodic(const Duration(seconds: 5), (_) => _savePos());
  }

  List<String> _siblings(String path) {
    try {
      final dir = File(path).parent;
      final files = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => isPlayable(p) && _isAudio == _audioExts.contains(_ext(p)))
          .toList()
        ..sort((a, b) => _natural(_name(a), _name(b)));
      return files.length > 300 ? [path] : files;
    } catch (_) {
      return [path];
    }
  }

  Future<void> _load(int index) async {
    final id = ++_loadId;
    await _savePos();
    final old = _c;
    old?.removeListener(_onTick);
    setState(() {
      _i = index;
      _c = null;
      _err = null;
      _ended = false;
      _cues = const [];
      _subOffsetMs = 0;
    });
    old?.dispose();
    final path = _list[index];
    final c = VideoPlayerController.file(File(path),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false));
    try {
      await c.initialize();
    } catch (e) {
      await c.dispose();
      if (mounted && id == _loadId) setState(() => _err = e.toString());
      return;
    }
    if (!mounted || id != _loadId) {
      await c.dispose();
      return;
    }
    // continue where the person stopped last time
    final saved = _prefs?.getInt('pos:$path') ?? 0;
    final dur = c.value.duration.inMilliseconds;
    if (saved > 3000 && dur > 0 && saved < dur - 8000) {
      await c.seekTo(Duration(milliseconds: saved));
    }
    await c.setPlaybackSpeed(_speed);
    c.addListener(_onTick);
    // sound level of this player follows the phone's volume
    await c.setVolume(1);
    await c.play();
    _chan.invokeMethod('keepOn', true).catchError((_) {});
    final wide = c.value.aspectRatio >= 1 && !_isAudio;
    _landscape = wide;
    _applyOrientation();
    setState(() => _c = c);
    _kickHide();
    loadSubtitles(path).then((s) {
      if (mounted && id == _loadId) {
        setState(() {
          _cues = s;
          _subFile = s.isEmpty ? null : '${path.substring(0, path.lastIndexOf('.'))}.srt';
        });
      }
    });
  }

  void _applyOrientation() {
    if (_isAudio) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } else if (_landscape) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  void _onTick() {
    final c = _c;
    if (c == null) return;
    final v = c.value;
    if (v.hasError && _err == null) {
      setState(() => _err = v.errorDescription ?? 'error');
      return;
    }
    final done = v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 300) &&
        !v.isPlaying;
    if (done && !_ended) {
      _ended = true;
      _prefs?.remove('pos:${_list[_i]}');
      if (_i + 1 < _list.length) {
        _load(_i + 1);
      } else {
        setState(() => _ui = true);
      }
    }
  }

  Future<void> _savePos() async {
    final c = _c;
    final p = _prefs;
    if (c == null || p == null || _i >= _list.length) return;
    final v = c.value;
    if (!v.isInitialized) return;
    final key = 'pos:${_list[_i]}';
    final pos = v.position.inMilliseconds;
    final dur = v.duration.inMilliseconds;
    if (pos < 3000 || (dur > 0 && pos > dur - 8000)) {
      await p.remove(key);
    } else {
      await p.setInt(key, pos);
    }
  }

  // ------------------------------------------------------------ controls

  void _kickHide() {
    _hideT?.cancel();
    if (_isAudio) return;
    _hideT = Timer(const Duration(seconds: 4), () {
      if (mounted && _panel == null && (_c?.value.isPlaying ?? false)) {
        setState(() => _ui = false);
      }
    });
  }

  void _toggleUi() {
    setState(() => _ui = !_ui);
    if (_ui) _kickHide();
  }

  void _showHud(IconData icon, String text) {
    _hud.value = _Hud(icon, text);
    _hudT?.cancel();
    _hudT = Timer(const Duration(milliseconds: 900), () => _hud.value = null);
  }

  Future<void> _seekBy(int seconds) async {
    final c = _c;
    if (c == null) return;
    final dur = c.value.duration;
    var t = c.value.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (t > dur) t = dur;
    await c.seekTo(t);
    _showHud(seconds > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
        '${seconds > 0 ? '+' : ''}$seconds s');
  }

  void _playPause() {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      if (_ended) {
        _ended = false;
        c.seekTo(Duration.zero);
      }
      c.play();
      _kickHide();
    }
    setState(() {});
  }

  Future<void> _setSpeed(double s) async {
    _speed = s;
    await _c?.setPlaybackSpeed(s);
    setState(() {});
  }

  void _cycleFit() {
    setState(() {
      if (_fit == BoxFit.contain) {
        _fit = BoxFit.cover;
        _showHud(Icons.zoom_out_map_rounded, tr('Zoom'));
      } else if (_fit == BoxFit.cover) {
        _fit = BoxFit.fill;
        _showHud(Icons.aspect_ratio_rounded, tr('Stretch'));
      } else {
        _fit = BoxFit.contain;
        _showHud(Icons.fit_screen_rounded, tr('Fit'));
      }
    });
  }

  void _rotate() {
    setState(() => _landscape = !_landscape);
    _applyOrientation();
  }

  Future<void> _enterPip() async {
    setState(() {
      _pip = true;
      _ui = false;
    });
    bool ok = false;
    try {
      ok = (await _chan.invokeMethod<bool>('pip')) ?? false;
    } catch (_) {}
    if (!ok && mounted) {
      setState(() {
        _pip = false;
        _ui = true;
      });
      _showHud(Icons.picture_in_picture_alt_rounded,
          tr('Picture in picture is not available'));
    }
  }

  Future<void> _external() async {
    await _c?.pause();
    await openExternal(_list[_i]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _savePos();
      if (!_pip && state == AppLifecycleState.paused) _c?.pause();
    }
  }

  @override
  void dispose() {
    _savePos();
    WidgetsBinding.instance.removeObserver(this);
    _hideT?.cancel();
    _saveT?.cancel();
    _hudT?.cancel();
    _chan.setMethodCallHandler(null);
    _chan.invokeMethod('keepOn', false).catchError((_) {});
    _chan.invokeMethod('setBrightness', -1.0).catchError((_) {});
    _c?.removeListener(_onTick);
    _c?.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ------------------------------------------------------------- gestures

  void _vertDrag(DragUpdateDetails d, Size size) {
    final left = _dragFromLeft;
    final delta = -d.delta.dy / (size.height * 0.7);
    if (left) {
      _bright = (_bright + delta).clamp(0.02, 1.0);
      _chan.invokeMethod('setBrightness', _bright).catchError((_) {});
      _showHud(Icons.brightness_6_rounded, '${(_bright * 100).round()}%');
    } else {
      _vol = (_vol + delta).clamp(0.0, 1.0);
      _chan.invokeMethod('setVolume', _vol).catchError((_) {});
      _showHud(_vol == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          '${(_vol * 100).round()}%');
    }
  }

  bool _dragFromLeft = true;

  void _horzStart() {
    final c = _c;
    if (c == null) return;
    _seeking = true;
    _dragDx = 0;
    _seekStartMs = c.value.position.inMilliseconds.toDouble();
    _seekTargetMs = _seekStartMs;
  }

  void _horzUpdate(DragUpdateDetails d, Size size) {
    final c = _c;
    if (c == null || !_seeking) return;
    _dragDx += d.delta.dx;
    final dur = c.value.duration.inMilliseconds.toDouble();
    // a swipe across the whole screen moves two minutes
    _seekTargetMs =
        (_seekStartMs + _dragDx / size.width * 120000).clamp(0.0, dur);
    final diff = ((_seekTargetMs - _seekStartMs) / 1000).round();
    _showHud(diff >= 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
        '${_fmt(Duration(milliseconds: _seekTargetMs.round()))}  (${diff >= 0 ? '+' : ''}$diff s)');
  }

  void _horzEnd() {
    if (_seeking) {
      _seeking = false;
      _c?.seekTo(Duration(milliseconds: _seekTargetMs.round()));
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_locked,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
              _surface(size),
              if (_err == null && _c != null && !_pip) _subtitle(size),
              if (_err == null && !_pip) _gestures(size),
              if (_c == null && _err == null)
                const Center(child: CircularProgressIndicator()),
              if (_err != null) _errorView(),
              if (!_pip && _err == null) _hudView(),
              if (!_pip && _err == null) _controls(),
              if (!_pip && _err == null && _panel != null) _panelView(),
            ],
          );
        }),
      ),
    );
  }

  Widget _surface(Size size) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return const SizedBox.expand();
    if (_isAudio) {
      return Container(
        color: const Color(0xFF0B1220),
        alignment: Alignment.center,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.music_note_rounded, size: 110, color: Color(0xFF8B5CF6)),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_name(_list[_i]),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ]),
      );
    }
    final v = c.value.size;
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: _fit,
          child: SizedBox(
              width: v.width <= 0 ? size.width : v.width,
              height: v.height <= 0 ? size.height : v.height,
              child: VideoPlayer(c)),
        ),
      ),
    );
  }

  Widget _subtitle(Size size) {
    final c = _c!;
    if (_cues.isEmpty || !_subsOn) return const SizedBox.shrink();
    return Positioned(
      left: 24,
      right: 24,
      bottom: _ui ? 96 : 28,
      child: ValueListenableBuilder<VideoPlayerValue>(
        valueListenable: c,
        builder: (_, v, __) {
          final t = cueAt(_cues, v.position.inMilliseconds - _subOffsetMs);
          if (t == null) return const SizedBox.shrink();
          return Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(t,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 17, height: 1.3)),
            ),
          );
        },
      ),
    );
  }

  Widget _gestures(Size size) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _toggleUi,
      onDoubleTapDown: (d) => _lastTapX = d.localPosition.dx,
      onDoubleTap: () {
        if (_locked || _isAudio) return;
        final x = _lastTapX;
        if (x < size.width / 3) {
          _seekBy(-10);
        } else if (x > size.width * 2 / 3) {
          _seekBy(10);
        } else {
          _playPause();
        }
      },
      onLongPressStart: (_) {
        if (_locked) return;
        _c?.setPlaybackSpeed(2);
        _showHud(Icons.speed_rounded, '2x');
      },
      onLongPressEnd: (_) => _c?.setPlaybackSpeed(_speed),
      onVerticalDragStart: (d) {
        if (_locked || _isAudio) return;
        _dragFromLeft = d.localPosition.dx < size.width / 2;
      },
      onVerticalDragUpdate: (d) {
        if (_locked || _isAudio) return;
        _vertDrag(d, size);
      },
      onHorizontalDragStart: (_) {
        if (!_locked) _horzStart();
      },
      onHorizontalDragUpdate: (d) {
        if (!_locked) _horzUpdate(d, size);
      },
      onHorizontalDragEnd: (_) => _horzEnd(),
    );
  }

  double _lastTapX = 0;

  Widget _hudView() => Center(
        child: IgnorePointer(
          child: ValueListenableBuilder<_Hud?>(
            valueListenable: _hud,
            builder: (_, h, __) => AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: h == null ? 0 : 1,
              child: h == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(h.icon, color: Colors.white),
                        const SizedBox(width: 10),
                        Text(h.text,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
            ),
          ),
        ),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.white70, size: 54),
            const SizedBox(height: 12),
            Text(tr('SDM player cannot play this file'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _external,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(tr('Open in another player')),
            ),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: Text(tr('Close'), style: const TextStyle(color: Colors.white70)),
            ),
          ]),
        ),
      );

  Widget _controls() {
    final c = _c;
    final visible = _ui || _locked && _ui;
    return IgnorePointer(
      ignoring: !_ui,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1 : 0,
        child: _locked ? _lockedOverlay() : _fullControls(c),
      ),
    );
  }

  Widget _lockedOverlay() => SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 16),
            child: IconButton.filledTonal(
              icon: const Icon(Icons.lock_rounded),
              onPressed: () {
                setState(() => _locked = false);
                _kickHide();
              },
            ),
          ),
        ),
      );

  Widget _icon(IconData i, VoidCallback? f, {double size = 26, String? tip}) =>
      IconButton(
        tooltip: tip,
        iconSize: size,
        color: Colors.white,
        disabledColor: Colors.white24,
        icon: Icon(i),
        onPressed: f == null
            ? null
            : () {
                f();
                _kickHide();
              },
      );

  Widget _fullControls(VideoPlayerController? c) {
    final playing = c?.value.isPlaying ?? false;
    Widget plain(IconData i, VoidCallback? f, {double size = 28}) => IconButton(
          iconSize: size,
          color: Colors.white,
          disabledColor: Colors.white24,
          icon: Icon(i),
          onPressed: f == null
              ? null
              : () {
                  f();
                  _kickHide();
                },
        );
    return Stack(children: [
      // top: back, name, subtitles, audio, more  (+ a small row under it)
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                plain(Icons.arrow_back_rounded, () => Navigator.maybePop(context)),
                Expanded(
                  child: Text(_list.isEmpty ? '' : _name(_list[_i]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                ),
                plain(Icons.music_note_rounded,
                    () => setState(() => _panel = _Panel.audio)),
                if (!_isAudio)
                  plain(Icons.subtitles_rounded,
                      () => setState(() => _panel = _Panel.sub)),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                  onSelected: (v) {
                    if (v == 'ext') _external();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                        value: 'ext', child: Text(tr('Open in another player'))),
                  ],
                ),
              ]),
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 4),
                child: Row(children: [
                  PopupMenuButton<String>(
                    tooltip: tr('Speed'),
                    onSelected: (v) => _setSpeed(double.parse(v)),
                    itemBuilder: (_) => [
                      for (final x in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                        CheckedPopupMenuItem<String>(
                            value: '$x', checked: _speed == x, child: Text('${x}x')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Text(
                          '${_speed == _speed.roundToDouble() ? _speed.toInt() : _speed}X',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
                  if (!_isAudio)
                    plain(Icons.screen_rotation_rounded, _rotate, size: 26),
                  plain(Icons.replay_10_rounded, () => _seekBy(-10), size: 26),
                  plain(Icons.forward_10_rounded, () => _seekBy(10), size: 26),
                ]),
              ),
            ]),
          ),
        ),
      ),
      // bottom: seek bar, then lock | previous play next | fit, picture-in-picture
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (c != null) _seekBar(c),
              SizedBox(
                height: 64,
                child: Stack(alignment: Alignment.center, children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: plain(
                        Icons.lock_open_rounded,
                        () => setState(() {
                              _locked = true;
                              _ui = false;
                            }),
                        size: 26),
                  ),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    plain(Icons.skip_previous_rounded,
                        _i > 0 ? () => _load(_i - 1) : null, size: 38),
                    const SizedBox(width: 22),
                    IconButton(
                      iconSize: 54,
                      color: Colors.white,
                      icon: Icon(playing
                          ? Icons.pause_rounded
                          : (_ended
                              ? Icons.replay_rounded
                              : Icons.play_arrow_rounded)),
                      onPressed: _playPause,
                    ),
                    const SizedBox(width: 22),
                    plain(Icons.skip_next_rounded,
                        _i + 1 < _list.length ? () => _load(_i + 1) : null,
                        size: 38),
                  ]),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (!_isAudio) plain(Icons.aspect_ratio_rounded, _cycleFit, size: 26),
                      if (!_isAudio)
                        plain(Icons.picture_in_picture_alt_rounded, _enterPip,
                            size: 26),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }

  // ------------------------------------------------- side panel (audio / subtitles)

  Widget _panelView() {
    final w = MediaQuery.sizeOf(context).width;
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
          child: Text(t,
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
        );
    Widget radio(String t, bool on, VoidCallback? f) => InkWell(
          onTap: f,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: on ? const Color(0xFF60A5FA) : Colors.white54, size: 28),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(t,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17))),
            ]),
          ),
        );
    Widget stepper(String label, String value, VoidCallback minus, VoidCallback plus) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 17))),
            IconButton.filledTonal(
                icon: const Icon(Icons.remove_rounded), onPressed: minus),
            Container(
              width: 84,
              height: 40,
              alignment: Alignment.center,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                  color: Colors.white10, borderRadius: BorderRadius.circular(6)),
              child: Text(value,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
            IconButton.filledTonal(
                icon: const Icon(Icons.add_rounded), onPressed: plus),
          ]),
        );
    final audio = _panel == _Panel.audio;
    final children = <Widget>[
      if (audio) ...[
        head(tr('Audio track')),
        radio(tr('Default audio track'), true, null),
        const Divider(color: Colors.white12),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Icon(_vol == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: Colors.white),
            Expanded(
              child: Slider(
                value: _vol,
                onChanged: (x) {
                  setState(() => _vol = x);
                  _chan.invokeMethod('setVolume', x).catchError((_) {});
                },
              ),
            ),
            Text('${(_vol * 100).round()}%',
                style: const TextStyle(color: Colors.white)),
          ]),
        ),
        const Divider(color: Colors.white12),
        InkWell(
          onTap: () {
            setState(() => _panel = null);
            _external();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              const Icon(Icons.open_in_new_rounded, color: Colors.white),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(tr('Other audio tracks or sound missing? Open in another player'),
                      style: const TextStyle(color: Colors.white, fontSize: 15))),
            ]),
          ),
        ),
      ] else ...[
        head(tr('Subtitle')),
        radio(tr('Disable'), !_subsOn || _cues.isEmpty,
            () => setState(() => _subsOn = false)),
        if (_cues.isNotEmpty)
          radio(
              _name(_subFile ?? tr('Subtitle file')),
              _subsOn,
              () => setState(() => _subsOn = true))
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
                tr('No subtitle found. Put an .srt or .vtt file with the same name next to the video.'),
                style: const TextStyle(color: Colors.white60, fontSize: 14)),
          ),
        const Divider(color: Colors.white12),
        stepper(
            tr('Synchronization'),
            '${(_subOffsetMs / 1000).toStringAsFixed(2)}s',
            () => setState(() => _subOffsetMs -= 250),
            () => setState(() => _subOffsetMs += 250)),
      ],
    ];
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _panel = null),
          child: Container(color: Colors.black38),
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: w > 700 ? 430 : w * 0.8,
        child: Material(
          color: Colors.black.withValues(alpha: 0.88),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: children,
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _seekBar(VideoPlayerController c) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (_, v, __) {
        final dur = v.duration.inMilliseconds.toDouble();
        final pos = (_dragV ?? v.position.inMilliseconds.toDouble())
            .clamp(0.0, dur <= 0 ? 1.0 : dur);
        double buffered = 0;
        if (v.buffered.isNotEmpty) {
          buffered = v.buffered.last.end.inMilliseconds.toDouble();
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Text(_fmt(Duration(milliseconds: pos.round())),
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  secondaryActiveTrackColor: Colors.white30,
                ),
                child: Slider(
                  value: pos,
                  secondaryTrackValue:
                      dur <= 0 ? null : buffered.clamp(0.0, dur),
                  min: 0,
                  max: dur <= 0 ? 1 : dur,
                  onChangeStart: (_) => _hideT?.cancel(),
                  onChanged: (x) => setState(() => _dragV = x),
                  onChangeEnd: (x) {
                    c.seekTo(Duration(milliseconds: x.round()));
                    setState(() => _dragV = null);
                    _kickHide();
                  },
                ),
              ),
            ),
            Text(_fmt(v.duration),
                style: const TextStyle(color: Colors.white, fontSize: 12.5)),
          ]),
        );
      },
    );
  }
}
