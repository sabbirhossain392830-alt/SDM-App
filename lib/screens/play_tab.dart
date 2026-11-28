import 'dart:io';

import 'package:flutter/material.dart';

import '../download_manager.dart';
import '../l10n.dart';
import '../models.dart';
import '../open_file.dart';
import '../player/player_screen.dart' show isPlayable, playInSdm;
import '../theme.dart';

/// Every finished video and song, ready to play in SDM's player.
class PlayTab extends StatefulWidget {
  final bool active;
  const PlayTab({super.key, required this.active});

  @override
  State<PlayTab> createState() => _PlayTabState();
}

class _PlayTabState extends State<PlayTab> {
  final dm = DownloadManager.instance;
  int _f = 0; // 0 all, 1 videos, 2 music

  bool _isMusic(String name) => FileKind.of(name).icon == Icons.music_note_rounded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListenableBuilder(
          listenable: dm,
          builder: (context, _) {
            if (!widget.active) return const SizedBox.shrink();
            final all = dm.items
                .where((d) =>
                    d.status == DlStatus.completed &&
                    isPlayable(d.savePath) &&
                    File(d.savePath).existsSync())
                .toList();
            final items = all.where((d) {
              if (_f == 0) return true;
              final m = _isMusic(d.fileName);
              return _f == 2 ? m : !m;
            }).toList();
            Widget chip(String label, int v) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(tr(label)),
                    selected: _f == v,
                    showCheckmark: false,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    onSelected: (_) => setState(() => _f = v),
                  ),
                );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                  child: Text(tr('Play'),
                      style: const TextStyle(
                          fontSize: 28, fontWeight: FontWeight.w800)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(children: [
                    chip('All', 0),
                    chip('Videos', 1),
                    chip('Music', 2),
                  ]),
                ),
                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_circle_outline_rounded,
                                      size: 64, color: cs.outline),
                                  const SizedBox(height: 12),
                                  Text(
                                      tr('No videos or songs yet. Download one and it shows up here.'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: cs.onSurfaceVariant,
                                          height: 1.4)),
                                ]),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: items.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (_, i) => _tile(items[i], cs),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tile(DownloadItem d, ColorScheme cs) {
    final kind = FileKind.of(d.fileName);
    final folder = d.dirPath.split('/').where((e) => e.isNotEmpty).lastOrNull ?? '';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => playInSdm(d.savePath),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: kind.color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(kind.icon, color: kind.color, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 15, height: 1.25)),
                  const SizedBox(height: 3),
                  Text(
                      '${formatBytes(d.total > 0 ? d.total : d.downloaded)} · $folder',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12.5)),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'ext') openExternal(d.savePath);
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'ext', child: Text(tr('Open in another app'))),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
