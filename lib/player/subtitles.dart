import 'dart:convert';
import 'dart:io';

/// One line of subtitles.
class SubCue {
  final int startMs;
  final int endMs;
  final String text;
  const SubCue(this.startMs, this.endMs, this.text);
}

/// Looks for subtitles next to the video: same name with .srt / .vtt.
Future<List<SubCue>> loadSubtitles(String videoPath) async {
  final dot = videoPath.lastIndexOf('.');
  if (dot < 0) return const [];
  final base = videoPath.substring(0, dot);
  for (final e in const ['srt', 'vtt', 'SRT', 'VTT']) {
    final f = File('$base.$e');
    try {
      if (await f.exists()) {
        final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
        final cues = parseSubtitles(text);
        if (cues.isNotEmpty) return cues;
      }
    } catch (_) {}
  }
  return const [];
}

final RegExp _time = RegExp(
    r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})');

int _ms(String? h, String m, String s, String f) {
  final frac = int.parse(f.padRight(3, '0').substring(0, 3));
  return ((int.tryParse(h ?? '0') ?? 0) * 3600 +
              int.parse(m) * 60 +
              int.parse(s)) *
          1000 +
      frac;
}

List<SubCue> parseSubtitles(String raw) {
  final text = raw.replaceAll('\r', '').replaceFirst('﻿', '');
  final out = <SubCue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final ti = lines.indexWhere((l) => l.contains('-->'));
    if (ti < 0) continue;
    final m = _time.firstMatch(lines[ti]);
    if (m == null) continue;
    final body = lines
        .sublist(ti + 1)
        .join('\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
        .trim();
    if (body.isEmpty) continue;
    out.add(SubCue(_ms(m[1], m[2]!, m[3]!, m[4]!), _ms(m[5], m[6]!, m[7]!, m[8]!),
        body));
  }
  out.sort((a, b) => a.startMs.compareTo(b.startMs));
  return out;
}

/// The line to show at [ms] (binary search), or null.
String? cueAt(List<SubCue> cues, int ms) {
  var lo = 0, hi = cues.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final c = cues[mid];
    if (ms < c.startMs) {
      hi = mid - 1;
    } else if (ms > c.endMs) {
      lo = mid + 1;
    } else {
      return c.text;
    }
  }
  return null;
}
