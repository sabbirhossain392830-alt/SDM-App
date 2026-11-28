import 'package:flutter/material.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'download_manager.dart';
import 'models.dart';
import 'sheet_style.dart';

/// True for a YouTube page link (youtube.com, youtu.be, ...).
bool isYoutubeLink(String url) {
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
  const hosts = ['youtube.com', 'youtu.be', 'youtube-nocookie.com'];
  return hosts.any((h) => host == h || host.endsWith('.$h'));
}

/// One thing the person can download: a video (with sound) or audio only.
class _Choice {
  final bool isAudio;
  final String label; // "720p - MP4"
  final Uri url;
  final int bytes; // -1 = unknown
  final String ext; // file extension without the dot
  final String mime;
  const _Choice({
    required this.isAudio,
    required this.label,
    required this.url,
    required this.bytes,
    required this.ext,
    required this.mime,
  });
}

class _Loaded {
  final String title;
  final List<_Choice> video;
  final List<_Choice> audio;
  const _Loaded(this.title, this.video, this.audio);
}

/// Quality text like "720p". The package's field name has changed between
/// versions, so this reads it safely and falls back to "Video".
String _quality(Object stream) {
  try {
    final q = (stream as dynamic).videoQualityLabel;
    if (q is String && q.isNotEmpty) return q;
  } catch (_) {}
  try {
    final h = (stream as dynamic).videoResolution.height;
    if (h is int && h > 0) return '${h}p';
  } catch (_) {}
  return 'Video';
}

String _cleanTitle(String t) {
  final s = t.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();
  return s.isEmpty ? 'youtube_video' : s;
}

Future<_Loaded> _load(String link) async {
  final yt = YoutubeExplode();
  try {
    final video = await yt.videos.get(link);
    final manifest = await yt.videos.streams.getManifest(video.id);

    // Video WITH sound (one file). Biggest file first = best quality first.
    final muxed = manifest.muxed.toList()
      ..sort((a, b) => b.size.totalBytes.compareTo(a.size.totalBytes));
    final videos = <_Choice>[];
    final seen = <String>{};
    for (final s in muxed) {
      final ext = s.container.name.toLowerCase();
      final label = '${_quality(s)} - ${ext.toUpperCase()}';
      if (!seen.add(label)) continue;
      videos.add(_Choice(
        isAudio: false,
        label: label,
        url: s.url,
        bytes: s.size.totalBytes,
        ext: ext,
        mime: 'video/$ext',
      ));
    }

    // Audio only: the biggest (best) file of each container type.
    final audioAll = manifest.audioOnly.toList()
      ..sort((a, b) => b.size.totalBytes.compareTo(a.size.totalBytes));
    final audios = <_Choice>[];
    final seenAudio = <String>{};
    for (final s in audioAll) {
      final c = s.container.name.toLowerCase();
      if (!seenAudio.add(c)) continue;
      // MP4 container with only audio is an .m4a file
      final ext = c == 'mp4' ? 'm4a' : c;
      audios.add(_Choice(
        isAudio: true,
        label: 'Audio - ${ext.toUpperCase()}',
        url: s.url,
        bytes: s.size.totalBytes,
        ext: ext,
        mime: 'audio/$c',
      ));
    }
    return _Loaded(video.title, videos, audios);
  } finally {
    yt.close();
  }
}

/// Bottom sheet: shows the video name and what can be downloaded.
Future<void> showYoutubeSheet(BuildContext context, String link) {
  return showSdmSheet<void>(context, builder: (_) => _YoutubeSheet(link: link));
}

class _YoutubeSheet extends StatefulWidget {
  final String link;
  const _YoutubeSheet({required this.link});

  @override
  State<_YoutubeSheet> createState() => _YoutubeSheetState();
}

class _YoutubeSheetState extends State<_YoutubeSheet> {
  late final Future<_Loaded> _future = _load(widget.link);

  Future<void> _pick(_Loaded data, _Choice c) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    void say(String m) => messenger?.showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(m)));
    try {
      await DownloadManager.instance.addUrl(
        c.url.toString(),
        suggestedName: '${_cleanTitle(data.title)}.${c.ext}',
        // The stream link comes from the player API, so SDM does not probe
        // it again. Audio-only (adaptive) streams are served in byte-range
        // pieces by YouTube, so they are downloaded with ranges; a plain
        // single request for them is often refused.
        probe: ProbeResult(c.bytes > 0 ? c.bytes : -1,
            c.isAudio && c.bytes > 0, null, c.mime),
      );
      say('Download started');
    } catch (e) {
      say('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: FutureBuilder<_Loaded>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError || snap.data == null) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not read this video. Check the link and your '
                  'internet, then try again.\n\n${snap.error ?? ''}',
                ),
              );
            }
            final data = snap.data!;
            final all = [...data.video, ...data.audio];
            return ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    data.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (all.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No downloadable stream found.'),
                  ),
                for (final c in all)
                  ListTile(
                    leading: Icon(c.isAudio ? Icons.music_note : Icons.movie),
                    title: Text(c.label),
                    subtitle:
                        Text(c.bytes > 0 ? formatBytes(c.bytes) : 'Size unknown'),
                    trailing: const Icon(Icons.download),
                    onTap: () => _pick(data, c),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
