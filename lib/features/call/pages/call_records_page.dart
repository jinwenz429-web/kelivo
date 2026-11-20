import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../call_launcher.dart';
import '../call_records.dart';

String _clock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month}月${t.day}日 ${two(t.hour)}:${two(t.minute)}';
}

String _length(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.inMinutes}:${two(d.inSeconds % 60)}';
}

/// All calls with one conversation, newest first.
class CallRecordsPage extends StatefulWidget {
  const CallRecordsPage({super.key, required this.conversationId});

  final String conversationId;

  @override
  State<CallRecordsPage> createState() => _CallRecordsPageState();
}

class _CallRecordsPageState extends State<CallRecordsPage> {
  bool _favoritesOnly = false;

  @override
  void initState() {
    super.initState();
    unawaited(CallRecordStore.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('通话记录'),
        actions: [
          IosIconButton(
            icon: Lucide.Star,
            color: _favoritesOnly ? cs.primary : null,
            semanticLabel: '只看收藏',
            onTap: () => setState(() => _favoritesOnly = !_favoritesOnly),
          ),
          IosIconButton(
            icon: Lucide.Phone,
            semanticLabel: '再打一通',
            onTap: () =>
                startCall(context, conversationId: widget.conversationId),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: CallRecordStore.instance,
        builder: (context, _) {
          final records = CallRecordStore.instance.records
              .where((r) => r.conversationId == widget.conversationId)
              .where(
                (r) => !_favoritesOnly || r.lines.any((line) => line.favorite),
              )
              .toList();
          if (records.isEmpty) {
            return Center(
              child: Text(
                _favoritesOnly ? '还没有收藏的语音' : '还没打过电话',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            );
          }
          return ListView.separated(
            itemCount: records.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = records[index];
              final incoming = r.direction == CallDirection.incoming;
              return ListTile(
                leading: Icon(
                  incoming ? Lucide.PhoneIncoming : Lucide.Phone,
                  color: cs.primary,
                ),
                title: Text('${_clock(r.startedAt)} · ${_length(r.duration)}'),
                subtitle: Text(
                  [
                    if (incoming && r.reason.isNotEmpty) '他打来：${r.reason}',
                    if (!r.uploaded) '记忆里还没有这通',
                  ].join(' · ').ifEmpty('${r.lines.length} 句'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CallRecordDetailPage(
                      record: r,
                      favoritesOnly: _favoritesOnly,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// One call's transcript, with the companion's lines playable.
class CallRecordDetailPage extends StatefulWidget {
  const CallRecordDetailPage({
    super.key,
    required this.record,
    this.favoritesOnly = false,
  });

  final CallRecord record;
  final bool favoritesOnly;

  @override
  State<CallRecordDetailPage> createState() => _CallRecordDetailPageState();
}

class _CallRecordDetailPageState extends State<CallRecordDetailPage> {
  final AudioPlayer _player = AudioPlayer();
  CallLine? _playing;
  int _playToken = 0;

  CallRecord get record => widget.record;

  @override
  void dispose() {
    _playToken++;
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _play(CallLine line) async {
    final token = ++_playToken;
    if (_playing == line) {
      await _player.stop();
      setState(() => _playing = null);
      return;
    }
    setState(() => _playing = line);
    for (final relative in line.audio) {
      if (token != _playToken) return;
      final path = await CallRecordStore.instance.audioPath(record, relative);
      final done = _player.onPlayerComplete.first;
      try {
        await _player.play(DeviceFileSource(path));
        await done;
      } catch (_) {
        break;
      }
    }
    if (token == _playToken && mounted) setState(() => _playing = null);
  }

  Future<void> _share(CallLine line) async {
    final files = <XFile>[
      for (final relative in line.audio)
        XFile(await CallRecordStore.instance.audioPath(record, relative)),
    ];
    if (files.isEmpty) return;
    await SharePlus.instance.share(ShareParams(files: files, text: line.text));
  }

  Future<void> _toggleFavorite(CallLine line) async {
    setState(() => line.favorite = !line.favorite);
    await CallRecordStore.instance.save(record);
  }

  Future<void> _retryUpload() async {
    final setup = resolveCallSetup(context, record.conversationId);
    if (setup == null) return;
    await finishCall(context, record, setup.provider);
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: record.uploaded ? '已经交给记忆了' : '还是没传上去',
      type: record.uploaded ? NotificationType.success : NotificationType.error,
    );
    setState(() {});
  }

  Future<void> _delete() async {
    await CallRecordStore.instance.delete(record);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lines = record.lines
        .where((l) => !widget.favoritesOnly || l.favorite)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${_clock(record.startedAt)} · ${_length(record.duration)}',
        ),
        actions: [
          if (!record.uploaded)
            IosIconButton(
              icon: Lucide.History,
              semanticLabel: '重新交给记忆',
              onTap: _retryUpload,
            ),
          IosIconButton(
            icon: Lucide.Trash2,
            semanticLabel: '删除这通记录',
            onTap: _delete,
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final line = lines[index];
          final mine = line.isUser;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    mine ? record.userName : record.assistantName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    line.interrupted ? '${line.text}—' : line.text,
                    style: TextStyle(
                      height: 1.45,
                      color: mine ? cs.onSurface.withValues(alpha: 0.7) : null,
                    ),
                  ),
                ),
                if (line.audio.isNotEmpty) ...[
                  IosIconButton(
                    icon: _playing == line ? Lucide.X : Lucide.Play,
                    size: 18,
                    semanticLabel: '播放',
                    onTap: () => _play(line),
                  ),
                  IosIconButton(
                    icon: Lucide.Star,
                    size: 18,
                    color: line.favorite ? cs.primary : null,
                    semanticLabel: '收藏',
                    onTap: () => _toggleFavorite(line),
                  ),
                  IosIconButton(
                    icon: Lucide.Download,
                    size: 18,
                    semanticLabel: '存下这句语音',
                    onTap: () => _share(line),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
