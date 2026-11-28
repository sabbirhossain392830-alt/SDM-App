import '../pull_refresh.dart';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../download_manager.dart';
import '../l10n.dart';
import '../sheet_style.dart';
import '../models.dart';
import 'browser_controller.dart';
import 'browser_tab.dart';
import 'download_prompt.dart';

/// Slim floating capsule with a small download icon. Drag it anywhere; tap it
/// to see everything that was found and pick what to download.
class MediaBubble extends StatefulWidget {
  final BrowserController browser;
  final BrowserTab tab;
  final void Function(DownloadRequest) onDownload;
  const MediaBubble({
    super.key,
    required this.browser,
    required this.tab,
    required this.onDownload,
  });

  @override
  State<MediaBubble> createState() => _MediaBubbleState();
}

class _MediaBubbleState extends State<MediaBubble> {
  static const double _w = 70;
  static const double _h = 34;
  Offset? _drag; // pixel position while dragging

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tab = widget.tab;
    final n = tab.media.length;
    return LayoutBuilder(builder: (context, box) {
      final maxX = (box.maxWidth - _w).clamp(0.0, double.infinity);
      final maxY = (box.maxHeight - _h).clamp(0.0, double.infinity);
      final b = widget.browser;
      final rest = Offset(b.bubbleX * maxX, b.bubbleY * maxY);
      final pos = _drag ?? rest;
      return Stack(
        children: [
          AnimatedPositioned(
            duration:
                _drag == null ? const Duration(milliseconds: 220) : Duration.zero,
            curve: Curves.easeOutCubic,
            left: pos.dx,
            top: pos.dy,
            child: GestureDetector(
              onPanStart: (_) => setState(() => _drag = rest),
              onPanUpdate: (d) => setState(() {
                final p = (_drag ?? rest) + d.delta;
                _drag = Offset(p.dx.clamp(0.0, maxX), p.dy.clamp(0.0, maxY));
              }),
              onPanEnd: (_) {
                final p = _drag ?? rest;
                // stick to the nearer side edge
                final x = (maxX <= 0) ? 1.0 : (p.dx / maxX >= 0.5 ? 1.0 : 0.0);
                final y = maxY <= 0 ? 0.0 : p.dy / maxY;
                setState(() => _drag = null);
                b.setBubble(x, y);
              },
              onTap: () => showMediaSheet(context, tab, widget.onDownload),
              child: TweenAnimationBuilder<double>(
                // a small bounce every time a new item is found
                key: ValueKey('bubble_$n'),
                tween: Tween(begin: 0.8, end: 1),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                // glass: see-through, frosted, so the page stays visible
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_h / 2),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: _drag != null ? 14 : 8,
                          offset: const Offset(0, 3)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_h / 2),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        width: _w,
                        height: _h,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_h / 2),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: dark ? 0.22 : 0.55),
                              Colors.white.withValues(alpha: dark ? 0.08 : 0.25),
                            ],
                          ),
                          border: Border.all(
                              color: Colors.white
                                  .withValues(alpha: dark ? 0.35 : 0.8)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.download_rounded,
                                color: const Color(0xFF5AB4FF),
                                size: 20),
                            if (n > 1) ...[
                              const SizedBox(width: 4),
                              Text('$n',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFF5AB4FF))),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

String _safe(String s) {
  var n = s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (n.length > 60) n = n.substring(0, 60).trim();
  return n;
}

String _qualityName(MediaEntry e) {
  if (e.audio) {
    if (e.label.isNotEmpty) return e.label;
    return tr('Audio');
  }
  final h = e.height;
  if (h <= 0) return e.label.isNotEmpty ? e.label : tr('Video');
  final tag = h >= 4320
      ? ' 8K'
      : h >= 2160
          ? ' 4K'
          : h >= 1440
              ? ' 2K'
              : h >= 1080
                  ? ' Full HD'
                  : h >= 720
                      ? ' HD'
                      : '';
  return '${h}p$tag';
}

String _fileNameFor(BrowserTab tab, MediaEntry e) {
  final base = _safe(tab.title.isNotEmpty ? tab.title : tab.host);
  final q = e.audio
      ? (e.label.isNotEmpty ? _safe(e.label) : 'audio')
      : (e.height > 0 ? '${e.height}p' : '');
  final name = [if (base.isNotEmpty) base else 'media', if (q.isNotEmpty) q].join(' ');
  return '$name.${e.ext}';
}

/// Lists the audio / video found on the page, best quality first.
Future<void> showMediaSheet(
  BuildContext context,
  BrowserTab tab,
  void Function(DownloadRequest) onDownload,
) {
  return showSdmSheet<void>(
    context,
    builder: (ctx) => _MediaSheet(
      tab: tab,
      onPick: (e) {
        Navigator.pop(ctx);
        onDownload(DownloadRequest(
          url: e.url,
          fileName: _fileNameFor(tab, e),
          referer: e.referer == '' ? null : (e.referer ?? tab.url),
          userAgent: tab.userAgent,
        ));
      },
    ),
  );
}

class _MediaSheet extends StatefulWidget {
  final BrowserTab tab;
  final void Function(MediaEntry) onPick;
  const _MediaSheet({required this.tab, required this.onPick});

  @override
  State<_MediaSheet> createState() => _MediaSheetState();
}

class _MediaSheetState extends State<_MediaSheet> {
  bool? _audioTab; // null = pick automatically

  List<MediaEntry> _sorted(bool audio) {
    final l = widget.tab.media.where((e) => e.audio == audio).toList();
    l.sort((a, b) {
      final h = b.height.compareTo(a.height);
      if (h != 0) return h;
      final bw = b.bandwidth.compareTo(a.bandwidth);
      if (bw != 0) return bw;
      return b.size.compareTo(a.size);
    });
    return l;
  }

  Widget _tabChip(ColorScheme cs, bool selected, IconData icon, String label,
      int count, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: selected
                ? const LinearGradient(
                    colors: [Color(0xFF4A5BE0), Color(0xFF6FA3FF)])
                : null,
            color: selected ? null : cs.surfaceContainerHighest,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 19, color: selected ? Colors.white : cs.onSurfaceVariant),
              const SizedBox(width: 7),
              Text('$label  $count',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: selected ? Colors.white : cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.tab,
      builder: (context, _) {
        final videos = _sorted(false);
        final audios = _sorted(true);
        final audioTab = _audioTab ?? (videos.isEmpty && audios.isNotEmpty);
        final list = audioTab ? audios : videos;
        final best = list.where((e) => e.downloadable).firstOrNull;
        final title = widget.tab.title.isNotEmpty
            ? widget.tab.title
            : widget.tab.host;
        return SizedBox(
          height: MediaQuery.of(context).size.height * 0.84,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Row(children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF4A5BE0), Color(0xFF6FA3FF)]),
                    ),
                    child: const Icon(Icons.download_for_offline_rounded,
                        color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const T('Audio / video on this page',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        if (title.isNotEmpty)
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12.5, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(children: [
                  _tabChip(cs, !audioTab, Icons.movie_rounded, tr('Video'),
                      videos.length, () => setState(() => _audioTab = false)),
                  const SizedBox(width: 10),
                  _tabChip(cs, audioTab, Icons.music_note_rounded, tr('Audio'),
                      audios.length, () => setState(() => _audioTab = true)),
                ]),
              ),
              if (best != null && list.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14))),
                      onPressed: () => widget.onPick(best),
                      icon: const Icon(Icons.bolt_rounded),
                      label: Text(
                          '${tr('Download best quality')} · ${_qualityName(best)}'),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                  audioTab
                                      ? Icons.music_off_rounded
                                      : Icons.videocam_off_rounded,
                                  size: 54,
                                  color: cs.outline),
                              const SizedBox(height: 12),
                              T(
                                audioTab
                                    ? 'No audio found yet. Play it on the page and it appears here.'
                                    : 'No video found yet. Play it on the page and it appears here.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    : PullRefresh(
                        child: ListView.separated(
                        physics: kPullPhysics,
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => _MediaRow(
                          key: ValueKey(list[i].url),
                          tab: widget.tab,
                          entry: list[i],
                          isBest:
                              i == 0 && list[i].downloadable && list.length > 1,
                          onPick: widget.onPick,
                        ),
                      )),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded, size: 15, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: T(
                      'Protected (DRM) videos and live streams cannot be downloaded.',
                      style: TextStyle(fontSize: 11.5, color: cs.outline),
                    ),
                  ),
                ]),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MediaRow extends StatefulWidget {
  final BrowserTab tab;
  final MediaEntry entry;
  final bool isBest;
  final void Function(MediaEntry) onPick;
  const _MediaRow({
    super.key,
    required this.tab,
    required this.entry,
    required this.isBest,
    required this.onPick,
  });

  @override
  State<_MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<_MediaRow> {
  MediaEntry get e => widget.entry;

  @override
  void initState() {
    super.initState();
    _askSize();
  }

  Future<void> _askSize() async {
    if (e.hls || e.size >= 0 || e.sizeAsked) return;
    e.sizeAsked = true;
    try {
      final h = await BrowserController.instance.pageHeaders(widget.tab, e.url);
      final p = await DownloadManager.instance.inspect(e.url, headers: h);
      if (p.total > 0) e.size = p.total;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _sizeText() {
    if (e.size > 0) return formatBytes(e.size);
    if (e.hls && e.bandwidth > 0 && e.seconds > 0) {
      return '~${formatBytes(e.bandwidth / 8 * e.seconds)}';
    }
    if (e.hls && e.bandwidth > 0) {
      return '${(e.bandwidth / 1000000).toStringAsFixed(1)} Mbps';
    }
    if (!e.hls && !e.sizeAsked) return tr('checking…');
    return '';
  }

  String _durText() {
    if (e.seconds <= 0) return '';
    final s = e.seconds.round();
    return s >= 3600
        ? '${s ~/ 3600}h ${(s % 3600) ~/ 60}m'
        : '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Color _badge() {
    if (e.audio) return const Color(0xFF8B5CF6);
    final h = e.height;
    if (h >= 2160) return const Color(0xFFE11D48);
    if (h >= 1080) return const Color(0xFF4A5BE0);
    if (h >= 720) return const Color(0xFF0EA5E9);
    return const Color(0xFF64748B);
  }

  Widget _chip(ColorScheme cs, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: cs.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.onSurfaceVariant)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    String? note;
    if (e.encrypted) note = 'Protected stream, cannot be downloaded';
    if (e.live) note = 'Live stream, cannot be downloaded';
    if (note == null && e.separateAudio) {
      note = 'Sound is a separate stream: also download it from the Audio tab';
    }
    final c = _badge();
    final size = _sizeText();
    final dur = _durText();
    final ok = e.downloadable;
    return Opacity(
      opacity: ok ? 1 : 0.6,
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
              color: widget.isBest
                  ? c.withValues(alpha: 0.7)
                  : cs.outlineVariant.withValues(alpha: 0.5),
              width: widget.isBest ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: ok ? () => widget.onPick(e) : null,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [c, c.withValues(alpha: 0.7)]),
                    ),
                    child: Icon(
                        e.audio
                            ? Icons.music_note_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 30),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Flexible(
                            child: Text(_qualityName(e),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w800)),
                          ),
                          if (widget.isBest) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF16A34A),
                                borderRadius: BorderRadius.circular(7),
                              ),
                              child: Text(tr('Best'),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ]),
                        const SizedBox(height: 7),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          _chip(cs, Icons.insert_drive_file_outlined,
                              e.hls ? 'HLS' : e.ext.toUpperCase()),
                          if (size.isNotEmpty)
                            _chip(cs, Icons.data_usage_rounded, size),
                          if (dur.isNotEmpty)
                            _chip(cs, Icons.schedule_rounded, dur),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ok
                      ? Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c,
                          ),
                          child: const Icon(Icons.download_rounded,
                              color: Colors.white),
                        )
                      : Icon(Icons.lock_outline_rounded, color: cs.error),
                ]),
                if (note != null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Icon(
                        (e.encrypted || e.live)
                            ? Icons.block_rounded
                            : Icons.info_outline_rounded,
                        size: 15,
                        color: (e.encrypted || e.live)
                            ? cs.error
                            : cs.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(tr(note),
                          style: TextStyle(
                              fontSize: 12,
                              color: (e.encrypted || e.live)
                                  ? cs.error
                                  : cs.onSurfaceVariant)),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
