import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'theme.dart';

/// Length and a picture of a video or song.
class MediaInfo {
  final int durationMs;
  final Uint8List? thumb;
  const MediaInfo(this.durationMs, this.thumb);
}

/// Asks Android for the thumbnail and length of a file, one file at a time,
/// and keeps the answers (in memory and in the app's cache folder).
class MediaMeta {
  static const _chan = MethodChannel('drom/media');
  static final Map<String, Future<MediaInfo?>> _mem = {};
  static Future<void> _tail = Future.value();
  static Directory? _dir;

  static Future<MediaInfo?> of(String path, {required bool audio}) =>
      _mem.putIfAbsent(path, () {
        final c = Completer<MediaInfo?>();
        _tail = _tail.then((_) async {
          try {
            c.complete(await _load(path, audio));
          } catch (_) {
            c.complete(null);
          }
        });
        return c.future;
      });

  static Future<MediaInfo?> _load(String path, bool audio) async {
    final f = File(path);
    if (!await f.exists()) return null;
    final st = await f.stat();
    final key =
        md5.convert(utf8.encode('$path|${st.size}|${st.modified.millisecondsSinceEpoch}')).toString();
    _dir ??= await Directory('${(await getTemporaryDirectory()).path}/sdm_thumbs')
        .create(recursive: true);
    final meta = File('${_dir!.path}/$key.json');
    final img = File('${_dir!.path}/$key.jpg');
    if (await meta.exists()) {
      try {
        final j = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
        return MediaInfo((j['d'] as num).toInt(),
            await img.exists() ? await img.readAsBytes() : null);
      } catch (_) {}
    }
    final r = await _chan
        .invokeMethod<Map<Object?, Object?>>('info', {'path': path, 'audio': audio});
    if (r == null) return null;
    final d = (r['duration'] as num?)?.toInt() ?? 0;
    final t = r['thumb'] as Uint8List?;
    try {
      if (t != null) await img.writeAsBytes(t);
      await meta.writeAsString(jsonEncode({'d': d}));
    } catch (_) {}
    return MediaInfo(d, t);
  }
}

/// Name, version and icon taken from inside an APK file.
class ApkInfo {
  final String label;
  final String version;
  final Uint8List? icon;
  const ApkInfo(this.label, this.version, this.icon);
}

class ApkMeta {
  static const _chan = MethodChannel('drom/apk');
  static final Map<String, Future<ApkInfo?>> _mem = {};

  static Future<ApkInfo?> of(String path) => _mem.putIfAbsent(path, () async {
        try {
          final r = await _chan
              .invokeMethod<Map<Object?, Object?>>('info', {'path': path});
          if (r == null) return null;
          return ApkInfo((r['label'] as String?) ?? '',
              (r['version'] as String?) ?? '', r['icon'] as Uint8List?);
        } catch (_) {
          return null;
        }
      });
}

bool isApkName(String n) => n.toLowerCase().endsWith('.apk');

String formatDuration(int ms) {
  final s = ms ~/ 1000;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(x)}' : '${two(m)}:${two(x)}';
}

bool isVideoName(String n) => FileKind.of(n).icon == Icons.play_circle_outline;
bool isAudioName(String n) => FileKind.of(n).icon == Icons.music_note_rounded;
bool isImageName(String n) => FileKind.of(n).icon == Icons.image_outlined;

/// Picture of a finished file: a video frame, the cover of a song, the image
/// itself, or the colourful type icon for everything else.
class MediaThumb extends StatelessWidget {
  final String path;
  final double size;
  const MediaThumb({super.key, required this.path, this.size = 72});

  @override
  Widget build(BuildContext context) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final kind = FileKind.of(name);
    final video = isVideoName(name), audio = isAudioName(name);
    final radius = BorderRadius.circular(12);
    Widget icon() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
              color: kind.color.withValues(alpha: 0.14), borderRadius: radius),
          child: Icon(kind.icon, color: kind.color, size: size * 0.5),
        );
    Widget framed(Widget child) => ClipRRect(
        borderRadius: radius,
        child: SizedBox(width: size, height: size, child: child));

    if (isImageName(name)) {
      return framed(Image.file(File(path),
          fit: BoxFit.cover,
          cacheWidth: (size * 3).round(),
          errorBuilder: (_, __, ___) => icon()));
    }
    if (isApkName(name)) {
      return FutureBuilder<ApkInfo?>(
        future: ApkMeta.of(path),
        builder: (_, snap) {
          final ic = snap.data?.icon;
          if (ic == null) return icon();
          return Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08), borderRadius: radius),
            child: Image.memory(ic, fit: BoxFit.contain, gaplessPlayback: true),
          );
        },
      );
    }
    if (!video && !audio) return icon();
    return FutureBuilder<MediaInfo?>(
      future: MediaMeta.of(path, audio: audio),
      builder: (_, snap) {
        final t = snap.data?.thumb;
        if (t == null) return icon();
        return framed(Stack(fit: StackFit.expand, children: [
          Image.memory(t, fit: BoxFit.cover, gaplessPlayback: true),
          if (video)
            Align(
              alignment: Alignment.bottomRight,
              child: Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(
                    color: Colors.black54, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 16),
              ),
            ),
        ]));
      },
    );
  }
}

/// The app name and version inside an APK ("WhatsApp · 2.24.1").
class ApkLabel extends StatelessWidget {
  final String path;
  final String fallback;
  final TextStyle? style;
  const ApkLabel(
      {super.key, required this.path, required this.fallback, this.style});

  @override
  Widget build(BuildContext context) => FutureBuilder<ApkInfo?>(
        future: ApkMeta.of(path),
        builder: (_, snap) {
          final i = snap.data;
          final t = (i == null || i.label.isEmpty)
              ? fallback
              : (i.version.isEmpty ? i.label : '${i.label} · ${i.version}');
          return Text(t == fallback ? fallback : '$t  |  $fallback',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
        },
      );
}

/// "05:00" for a video or song (empty until known).
class MediaDuration extends StatelessWidget {
  final String path;
  final TextStyle? style;
  const MediaDuration({super.key, required this.path, this.style});

  @override
  Widget build(BuildContext context) {
    final name = path.substring(path.lastIndexOf('/') + 1);
    final audio = isAudioName(name);
    return FutureBuilder<MediaInfo?>(
      future: MediaMeta.of(path, audio: audio),
      builder: (_, snap) {
        final d = snap.data?.durationMs ?? 0;
        return Text(d > 0 ? formatDuration(d) : '--:--', style: style);
      },
    );
  }
}
