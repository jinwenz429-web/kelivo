import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One spoken line of a call.
class CallLine {
  CallLine({
    required this.role,
    required this.text,
    required this.at,
    List<String>? audio,
    this.favorite = false,
    this.interrupted = false,
    this.soft = false,
  }) : audio = audio ?? <String>[];

  /// 'user' or 'assistant'.
  final String role;
  String text;
  final DateTime at;

  /// Audio files of this line (the companion's sentences), relative to the
  /// call's directory.
  final List<String> audio;
  bool favorite;

  /// The companion was cut off; [text] holds only what was actually heard.
  bool interrupted;

  /// The user spoke noticeably softer than usual.
  final bool soft;

  bool get isUser => role == 'user';

  Map<String, dynamic> toJson() => {
    'role': role,
    'text': text,
    'at': at.toUtc().toIso8601String(),
    if (audio.isNotEmpty) 'audio': audio,
    if (favorite) 'favorite': true,
    if (interrupted) 'interrupted': true,
    if (soft) 'soft': true,
  };

  static CallLine fromJson(Map<String, dynamic> json) => CallLine(
    role: json['role'] == 'user' ? 'user' : 'assistant',
    text: (json['text'] ?? '').toString(),
    at:
        DateTime.tryParse((json['at'] ?? '').toString())?.toLocal() ??
        DateTime.now(),
    audio: (json['audio'] as List? ?? const []).map((e) => '$e').toList(),
    favorite: json['favorite'] == true,
    interrupted: json['interrupted'] == true,
    soft: json['soft'] == true,
  );
}

enum CallDirection { outgoing, incoming }

/// A finished (or interrupted) call, kept on the phone.
class CallRecord {
  CallRecord({
    required this.id,
    required this.conversationId,
    required this.assistantId,
    required this.assistantName,
    required this.userName,
    required this.startedAt,
    this.endedAt,
    this.direction = CallDirection.outgoing,
    this.reason = '',
    List<CallLine>? lines,
    this.uploaded = false,
    this.insertedIntoChat = false,
  }) : lines = lines ?? <CallLine>[];

  final String id;
  final String conversationId;
  final String assistantId;
  final String assistantName;
  final String userName;
  final DateTime startedAt;
  DateTime? endedAt;
  final CallDirection direction;

  /// Why the companion called, for incoming calls.
  final String reason;
  final List<CallLine> lines;

  /// The transcript reached the memory gateway.
  bool uploaded;

  /// The stored round was copied into the local conversation.
  bool insertedIntoChat;

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'assistantId': assistantId,
    'assistantName': assistantName,
    'userName': userName,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'direction': direction.name,
    if (reason.isNotEmpty) 'reason': reason,
    'lines': lines.map((l) => l.toJson()).toList(),
    'uploaded': uploaded,
    'insertedIntoChat': insertedIntoChat,
  };

  static CallRecord fromJson(Map<String, dynamic> json) => CallRecord(
    id: json['id'].toString(),
    conversationId: (json['conversationId'] ?? '').toString(),
    assistantId: (json['assistantId'] ?? '').toString(),
    assistantName: (json['assistantName'] ?? '').toString(),
    userName: (json['userName'] ?? '').toString(),
    startedAt:
        DateTime.tryParse((json['startedAt'] ?? '').toString())?.toLocal() ??
        DateTime.now(),
    endedAt: DateTime.tryParse((json['endedAt'] ?? '').toString())?.toLocal(),
    direction: json['direction'] == 'incoming'
        ? CallDirection.incoming
        : CallDirection.outgoing,
    reason: (json['reason'] ?? '').toString(),
    lines: (json['lines'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => CallLine.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    uploaded: json['uploaded'] == true,
    insertedIntoChat: json['insertedIntoChat'] == true,
  );
}

/// The two messages a memory gateway stored for a call.
class StoredCallRound {
  const StoredCallRound(this.userContent, this.assistantContent);
  final String userContent;
  final String assistantContent;
}

/// Call records live as JSON plus audio files under the app's documents.
class CallRecordStore extends ChangeNotifier {
  CallRecordStore._();

  static final CallRecordStore instance = CallRecordStore._();

  io.Directory? _root;
  final List<CallRecord> _records = <CallRecord>[];
  bool _loaded = false;

  List<CallRecord> get records => List.unmodifiable(_records);

  Future<io.Directory> root() async {
    final existing = _root;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final dir = io.Directory(p.join(docs.path, 'calls'));
    await dir.create(recursive: true);
    return _root = dir;
  }

  Future<io.Directory> directoryFor(String callId) async {
    final dir = io.Directory(p.join((await root()).path, callId));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final dir = await root();
    final loaded = <CallRecord>[];
    await for (final entry in dir.list()) {
      if (entry is! io.Directory) continue;
      final file = io.File(p.join(entry.path, 'call.json'));
      if (!await file.exists()) continue;
      try {
        loaded.add(
          CallRecord.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(await file.readAsString()) as Map,
            ),
          ),
        );
      } catch (_) {}
    }
    loaded.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    _records
      ..clear()
      ..addAll(loaded);
    notifyListeners();
  }

  Future<void> save(CallRecord record) async {
    final dir = await directoryFor(record.id);
    final file = io.File(p.join(dir.path, 'call.json'));
    final tmp = io.File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await tmp.rename(file.path);
    _records.removeWhere((r) => r.id == record.id);
    _records.insert(0, record);
    _records.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    notifyListeners();
  }

  Future<void> delete(CallRecord record) async {
    final dir = await directoryFor(record.id);
    if (await dir.exists()) await dir.delete(recursive: true);
    _records.removeWhere((r) => r.id == record.id);
    notifyListeners();
  }

  Future<String> audioPath(CallRecord record, String relative) async =>
      p.join((await directoryFor(record.id)).path, relative);

  /// Posts the transcript to a Pawwake-style gateway. Returns the stored
  /// round, or null when the gateway has no call endpoint.
  static Future<StoredCallRound?> upload({
    required CallRecord record,
    required String baseUrl,
    required String apiKey,
    Map<String, String> headers = const {},
  }) async {
    final lines = [
      for (final line in record.lines)
        if (line.text.trim().isNotEmpty)
          {
            'role': line.role,
            'text': line.text,
            'at': line.at.toUtc().toIso8601String(),
          },
    ];
    if (lines.isEmpty) return null;
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse(
      '$base/calls/${Uri.encodeComponent(record.id)}/transcript',
    );
    final response = await http
        .post(
          uri,
          headers: {
            ...headers,
            'Content-Type': 'application/json',
            if (apiKey.trim().isNotEmpty)
              'Authorization': 'Bearer ${apiKey.trim()}',
            'X-Conversation-Id': record.conversationId,
          },
          body: jsonEncode({
            'conversation_id': record.conversationId,
            'lines': lines,
            'started_at': record.startedAt.toUtc().toIso8601String(),
            'ended_at': (record.endedAt ?? DateTime.now())
                .toUtc()
                .toIso8601String(),
            'user_label': record.userName,
            'assistant_label': record.assistantName,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404 || response.statusCode == 405) return null;
    if (response.statusCode != 200) {
      throw http.ClientException(
        'call transcript upload failed: ${response.statusCode}',
        uri,
      );
    }
    final json = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
    final user = (json['user_content'] ?? '').toString();
    final assistant = (json['assistant_content'] ?? '').toString();
    if (user.isEmpty) return null;
    return StoredCallRound(user, assistant);
  }
}
