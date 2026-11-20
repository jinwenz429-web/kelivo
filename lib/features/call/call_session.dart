import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/models/model_spec.dart' show ReasoningLevel;
import '../../core/models/reasoning_request.dart';
import '../../core/providers/settings_provider.dart' show ProviderConfig;
import '../../core/services/api/chat_api_service.dart';
import '../../core/services/api/stream/stream_chunk.dart';
import '../../core/services/asr/asr_service_options.dart';
import '../../core/services/tts/network_tts.dart';
import 'call_listener.dart';
import 'call_records.dart';
import 'call_settings.dart';
import 'call_text.dart';
import 'call_voice.dart';

enum CallPhase { connecting, listening, thinking, speaking, lingering, ended }

/// The memory lookup a call may use, already bound to its MCP server.
class CallMemoryTool {
  const CallMemoryTool({required this.definition, required this.call});

  /// OpenAI-style function definition named `search_memory`.
  final Map<String, dynamic> definition;
  final Future<String> Function(Map<String, dynamic> args) call;
}

/// Learns how loudly the user usually talks, to notice when she whispers.
class CallVoiceBaseline {
  CallVoiceBaseline({this.mean = 0, this.samples = 0});

  double mean;
  int samples;

  static const _minSamples = 5;

  bool isSoft(double level) =>
      samples >= _minSamples && level > 0 && level < mean * 0.62;

  void add(double level) {
    if (level <= 0) return;
    samples++;
    final weight = samples < 20 ? 1 / samples : 0.05;
    mean += (level - mean) * weight;
  }
}

/// One live call: listen, send, speak, get interrupted, hang up.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.record,
    required this.settings,
    required this.provider,
    required this.modelId,
    required this.systemPrompt,
    required TtsServiceOptions ttsService,
    required this.asrOptions,
    required this.baseline,
    required this._speakerMode,
    this.memoryTool,
    this.openingReason,
    this.onDndChanged,
  }) : ttsService = CallVoice.withCallModel(ttsService, settings.voiceModel);

  final CallRecord record;
  final CallSettings settings;
  final ProviderConfig provider;
  final String modelId;
  final String systemPrompt;
  final TtsServiceOptions ttsService;
  final AsrServiceOptions asrOptions;
  final CallVoiceBaseline baseline;
  final CallMemoryTool? memoryTool;

  /// Set when the companion placed the call.
  final String? openingReason;
  final void Function(bool on)? onDndChanged;

  late final bool _audioTags = CallVoice.readsAudioTags(ttsService);
  late CallVoice _voice;
  late CallListener _listener;
  bool _speakerMode;

  CallPhase _phase = CallPhase.connecting;
  String? _error;
  String? _notice;
  bool _muted = false;

  String? _requestId;
  StreamSubscription<StreamChunk>? _stream;
  CallLine? _replyLine;
  final List<CallUtterance> _replyUtterances = <CallUtterance>[];
  bool _turnAudioStarted = false;
  bool _fillerSaid = false;
  bool _hangupRequested = false;
  bool _replyPending = false;
  DateTime? _lastUserSentAt;
  DateTime _lastActivity = DateTime.now();
  int _nudges = 0;
  Timer? _ticker;
  Timer? _linger;
  bool _closed = false;

  static const _mergeWindow = Duration(seconds: 3);
  static const _lingerWindow = Duration(seconds: 15);
  static const _fillerLine = '嗯……我想想。';

  CallPhase get phase => _phase;
  String? get error => _error;

  /// A short status line for the UI (e.g. "他在查记忆").
  String? get notice => _notice;
  bool get muted => _muted;
  bool get speakerMode => _speakerMode;
  bool get userSpeaking => _listener.userSpeaking;
  double get micLevel => _listener.level;
  List<CallLine> get lines => record.lines;

  Future<void> start() async {
    final dir = await CallRecordStore.instance.directoryFor(record.id);
    _voice = CallVoice(
      service: ttsService,
      audioDirectory: dir,
      speakerMode: _speakerMode,
    )..onStarted = _onUtteranceStarted;
    _voice.onDrained = _onDrained;
    _voice.onError = (error) => _setNotice('有一句没念出来：$error');
    await _voice.prepare();
    _listener =
        CallListener(
            options: asrOptions,
            settings: settings,
            speakerMode: _speakerMode,
          )
          ..onSpeechStarted = _onUserStartedSpeaking
          ..onHeard = _onHeard
          ..onError = (error) => _setNotice('语音识别出错，已重新开始听：$error');
    await _listener.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    if (openingReason != null || settings.companionSpeaksFirst) {
      _respond(cue: callOpeningCue(reason: openingReason));
    } else {
      _setPhase(CallPhase.listening);
    }
  }

  // ---------------------------------------------------------------------------
  // Hearing the user

  void _onUserStartedSpeaking() {
    _lastActivity = DateTime.now();
    // Only an actual voice counts as an interruption; while the reply is
    // still being thought up, a stray sound must not throw it away.
    if (_phase == CallPhase.speaking) {
      _interrupt();
      _setPhase(CallPhase.listening);
    } else if (_phase == CallPhase.lingering) {
      _linger?.cancel();
      _hangupRequested = false;
      _setNotice(null);
      _setPhase(CallPhase.listening);
    }
    notifyListeners();
  }

  void _onHeard(CallHeard heard) {
    if (_closed) return;
    _lastActivity = DateTime.now();
    final busy = _requestId != null || _voice.isSpeaking;
    // A cough or an "嗯" does not take over a reply already on its way.
    if (busy && isSlightUtterance(heard.text)) return;
    final soft = baseline.isSoft(heard.averageLevel);
    baseline.add(heard.averageLevel);
    _nudges = 0;
    record.lines.add(
      CallLine(role: 'user', text: heard.text, at: DateTime.now(), soft: soft),
    );
    unawaited(_voice.setVolume(soft ? 0.55 : 1.0));
    notifyListeners();

    if (_requestId != null && !_turnAudioStarted) {
      final sentAt = _lastUserSentAt;
      if (sentAt != null && DateTime.now().difference(sentAt) < _mergeWindow) {
        // She had not finished: answer both sentences together.
        _cancelRequest(dropReplyLine: true);
        _respond();
      } else {
        // A separate thought: answer it right after the current reply.
        _replyPending = true;
      }
      return;
    }
    if (_voice.isSpeaking) {
      _replyPending = true;
      return;
    }
    _respond();
  }

  // ---------------------------------------------------------------------------
  // Asking the model

  List<Map<String, dynamic>> _requestMessages({String? cue}) {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
    ];
    for (final line in record.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final content = line.isUser && line.soft ? '$callSoftPrefix$text' : text;
      final last = messages.last;
      if (last['role'] == line.role) {
        last['content'] = '${last['content']}\n$content';
      } else {
        messages.add({'role': line.role, 'content': content});
      }
    }
    if (cue != null) {
      if (messages.last['role'] == 'user') {
        messages.last['content'] = '${messages.last['content']}\n\n$cue';
      } else {
        messages.add({'role': 'user', 'content': cue});
      }
    }
    return messages;
  }

  void _respond({String? cue}) {
    if (_closed) return;
    final messages = _requestMessages(cue: cue);
    if (messages.last['role'] != 'user') return;
    _replyPending = false;
    _turnAudioStarted = false;
    _fillerSaid = false;
    _replyUtterances.clear();
    _lastUserSentAt = cue == null ? DateTime.now() : null;
    final line = _replyLine = CallLine(
      role: 'assistant',
      text: '',
      at: DateTime.now(),
    );
    record.lines.add(line);
    final requestId = _requestId = 'call-${const Uuid().v4()}';
    final splitter = CallSentenceSplitter();
    _setPhase(CallPhase.thinking);

    final tool = memoryTool;
    final ToolCallHandler? onToolCall = tool == null
        ? null
        : (name, args, {toolCallId}) async {
            if (!name.endsWith('search_memory')) return '这个工具在电话里用不了。';
            return tool.call(args);
          };

    final stream = ChatApiService.sendMessageStream(
      config: provider,
      modelId: modelId,
      messages: messages,
      reasoning: settings.lowReasoning
          ? const ReasoningRequest(ReasoningLevel.low)
          : ReasoningRequest.auto,
      tools: tool == null ? null : [tool.definition],
      onToolCall: onToolCall,
      extraHeaders: {
        'X-Call-Id': record.id,
        'X-Conversation-Id': record.conversationId,
      },
      requestId: requestId,
      conversationId: record.conversationId,
      builtInToolMode: BuiltInToolMode.none,
      skipImageParsing: true,
      parseMarkdownImageLinks: false,
    );
    _stream = stream.listen(
      (chunk) {
        if (_requestId != requestId) return;
        switch (chunk) {
          case TextDelta(:final text):
            for (final sentence in splitter.add(text)) {
              _speakSentence(sentence);
            }
          case ToolCallStart():
            if (!_turnAudioStarted && !_fillerSaid) {
              _fillerSaid = true;
              _setNotice('他在翻记忆');
              _voice.say(_fillerLine, _fillerLine);
            }
          default:
            break;
        }
      },
      onError: (Object error) {
        if (_requestId != requestId) return;
        _requestId = null;
        _stream = null;
        _setError('这一句没发出去：$error');
        _finishReply(line);
      },
      onDone: () {
        if (_requestId != requestId) return;
        final rest = splitter.flush();
        if (rest.isNotEmpty) _speakSentence(rest);
        _requestId = null;
        _stream = null;
        _finishReply(line);
      },
      cancelOnError: true,
    );
  }

  void _speakSentence(String raw) {
    final (text, markers) = takeCallMarkers(raw);
    if (markers.contains(CallMarker.hangup)) _hangupRequested = true;
    if (markers.contains(CallMarker.dndOn)) onDndChanged?.call(true);
    if (markers.contains(CallMarker.dndOff)) onDndChanged?.call(false);
    final display = callDisplayText(text);
    final speech = callSpeechText(text, keepAudioTags: _audioTags);
    if (!callHasWords(speech)) return;
    _replyUtterances.add(_voice.say(speech, display));
    final line = _replyLine;
    if (line != null) {
      line.text = line.text.isEmpty ? display : '${line.text}$display';
      notifyListeners();
    }
  }

  void _onUtteranceStarted(CallUtterance utterance) {
    if (_closed) return;
    if (utterance.display != _fillerLine) {
      _turnAudioStarted = true;
      _setNotice(null);
      final line = _replyLine;
      if (line != null) {
        unawaited(
          utterance.audio.then((file) {
            if (record.lines.contains(line)) {
              line.audio.add(p.basename(file.path));
            }
          }, onError: (_) {}),
        );
      }
    }
    _listener.companionSpeaking = true;
    if (_phase != CallPhase.lingering) _setPhase(CallPhase.speaking);
  }

  void _finishReply(CallLine line) {
    if (line.text.trim().isEmpty) {
      record.lines.remove(line);
      if (!_voice.isSpeaking && _error == null) {
        _setNotice('这一轮他没出声');
      }
    }
    if (!_voice.isSpeaking) _onDrained();
    notifyListeners();
  }

  void _onDrained() {
    if (_closed) return;
    if (_requestId != null) return; // more sentences are on the way
    _listener.companionSpeaking = false;
    _lastActivity = DateTime.now();
    if (_hangupRequested) {
      _setPhase(CallPhase.lingering);
      _linger?.cancel();
      _linger = Timer(_lingerWindow, () {
        if (_phase == CallPhase.lingering && !_listener.userSpeaking) {
          unawaited(hangUp());
        }
      });
      return;
    }
    // Whatever the mic caught while it was talking was mostly its own voice.
    unawaited(_listener.restart());
    if (_replyPending) {
      _respond();
    } else {
      _setPhase(CallPhase.listening);
    }
  }

  /// The user cut in: keep only what was actually heard.
  void _interrupt() {
    final line = _replyLine;
    _cancelRequest(dropReplyLine: false);
    unawaited(_voice.stop());
    _listener.companionSpeaking = false;
    if (line != null) {
      final heard = _replyUtterances
          .where((u) => u.started && u.display != _fillerLine)
          .map((u) => u.display)
          .join();
      line
        ..text = heard
        ..interrupted = true;
      if (heard.trim().isEmpty) record.lines.remove(line);
    }
    _hangupRequested = false;
    _replyUtterances.clear();
  }

  void _cancelRequest({required bool dropReplyLine}) {
    final id = _requestId;
    _requestId = null;
    if (id != null) ChatApiService.cancelRequest(id);
    unawaited(_stream?.cancel());
    _stream = null;
    if (dropReplyLine) {
      final line = _replyLine;
      if (line != null) record.lines.remove(line);
      unawaited(_voice.stop());
    }
  }

  // ---------------------------------------------------------------------------
  // Quiet line

  void _tick() {
    if (_closed) return;
    notifyListeners(); // mic level meter
    if (!settings.silenceNudge || _phase != CallPhase.listening) return;
    if (_listener.userSpeaking || _nudges >= 2) return;
    final quiet = DateTime.now().difference(_lastActivity);
    if (quiet.inSeconds >= settings.silenceNudgeSeconds) {
      _nudges++;
      _respond(cue: callSilenceCue);
    }
  }

  // ---------------------------------------------------------------------------
  // Controls

  void toggleMute() {
    _muted = !_muted;
    _listener.muted = _muted;
    notifyListeners();
  }

  Future<void> setSpeakerMode(bool value) async {
    if (_speakerMode == value) return;
    _speakerMode = value;
    notifyListeners();
    await _voice.setSpeakerMode(value);
    await _listener.setSpeakerMode(value);
  }

  /// Stops talking now (the user tapped "stop").
  void cutIn() {
    if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) {
      _interrupt();
      _setPhase(CallPhase.listening);
    }
  }

  Future<void> hangUp() async {
    if (_closed) return;
    _closed = true;
    _ticker?.cancel();
    _linger?.cancel();
    _cancelRequest(dropReplyLine: false);
    final line = _replyLine;
    if (line != null && line.text.trim().isEmpty) record.lines.remove(line);
    await _voice.dispose();
    await _listener.close();
    record.endedAt = DateTime.now();
    _phase = CallPhase.ended;
    notifyListeners();
  }

  void _setPhase(CallPhase phase) {
    if (_phase == phase || _closed) return;
    _phase = phase;
    notifyListeners();
  }

  void _setNotice(String? notice) {
    _notice = notice;
    notifyListeners();
  }

  void _setError(String error) {
    _error = error;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_closed) unawaited(hangUp());
    super.dispose();
  }
}
