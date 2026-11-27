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
      if (mounted && id == _loadId) setState(() => _cues = s);
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
      if (mounted && (_c?.value.isPlaying ?? false)) setState(() => _ui = false);
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
    return Stack(children: [
      // top
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
            child: Row(children: [
              _icon(Icons.arrow_back_rounded, () => Navigator.maybePop(context)),
              Expanded(
                child: Text(_list.isEmpty ? '' : _name(_list[_i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              if (_cues.isNotEmpty)
                _icon(
                    _subsOn
                        ? Icons.closed_caption_rounded
                        : Icons.closed_caption_disabled_rounded,
                    () => setState(() => _subsOn = !_subsOn)),
              PopupMenuButton<String>(
                tooltip: tr('Speed'),
                icon: const Icon(Icons.speed_rounded, color: Colors.white),
                onSelected: (v) => _setSpeed(double.parse(v)),
                itemBuilder: (_) => [
                  for (final s in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                    CheckedPopupMenuItem<String>(
                        value: '$s', checked: _speed == s, child: Text('${s}x')),
                ],
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                onSelected: (v) {
                  switch (v) {
                    case 'pip':
                      _enterPip();
                    case 'ext':
                      _external();
                    case 'sub+':
                      setState(() => _subOffsetMs += 500);
                      _showHud(Icons.subtitles_rounded,
                          '${(_subOffsetMs / 1000).toStringAsFixed(1)} s');
                    case 'sub-':
                      setState(() => _subOffsetMs -= 500);
                      _showHud(Icons.subtitles_rounded,
                          '${(_subOffsetMs / 1000).toStringAsFixed(1)} s');
                  }
                },
                itemBuilder: (_) => [
                  if (!_isAudio)
                    PopupMenuItem(
                        value: 'pip', child: Text(tr('Picture in picture'))),
                  PopupMenuItem(
                      value: 'ext', child: Text(tr('Open in another player'))),
                  if (_cues.isNotEmpty) ...[
                    PopupMenuItem(
                        value: 'sub+', child: Text(tr('Subtitles later +0.5 s'))),
                    PopupMenuItem(
                        value: 'sub-', child: Text(tr('Subtitles earlier −0.5 s'))),
                  ],
                ],
              ),
            ]),
          ),
        ),
      ),
      // bottom
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
              Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                _icon(Icons.lock_open_rounded, () => setState(() {
                      _locked = true;
                      _ui = false;
                    }), size: 22),
                _icon(Icons.skip_previous_rounded,
                    _i > 0 ? () => _load(_i - 1) : null, size: 30),
                _icon(Icons.replay_10_rounded, () => _seekBy(-10), size: 28),
                IconButton.filled(
                  iconSize: 34,
                  icon: Icon(playing
                      ? Icons.pause_rounded
                      : (_ended ? Icons.replay_rounded : Icons.play_arrow_rounded)),
                  onPressed: _playPause,
                ),
                _icon(Icons.forward_10_rounded, () => _seekBy(10), size: 28),
                _icon(Icons.skip_next_rounded,
                    _i + 1 < _list.length ? () => _load(_i + 1) : null, size: 30),
                if (!_isAudio) ...[
                  _icon(Icons.aspect_ratio_rounded, _cycleFit, size: 22),
                  _icon(Icons.screen_rotation_rounded, _rotate, size: 22),
                ],
              ]),
              const SizedBox(height: 4),
            ]),
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
