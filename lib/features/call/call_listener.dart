import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../../core/providers/asr_provider.dart';
import '../../core/services/asr/asr_audio_capture.dart';
import '../../core/services/asr/asr_service_options.dart';
import 'call_settings.dart';

/// Microphone capture for calls. In speaker mode it records as a phone call
/// does, so Android's echo cancellation removes the companion's own voice.
final class CallAudioCapture implements AsrAudioCapture {
  CallAudioCapture({required this.speakerMode}) : _recorder = AudioRecorder();

  final bool speakerMode;
  final AudioRecorder _recorder;
  bool _started = false;
  bool _disposed = false;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start({required int sampleRate}) async {
    if (_started) throw StateError('Call capture is already active.');
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: speakerMode,
        noiseSuppress: speakerMode,
        streamBufferSize: 2048,
        androidConfig: AndroidRecordConfig(
          audioSource: speakerMode
              ? AndroidAudioSource.voiceCommunication
              : AndroidAudioSource.voiceRecognition,
          audioManagerMode: speakerMode
              ? AudioManagerMode.modeInCommunication
              : AudioManagerMode.modeNormal,
          speakerphone: speakerMode,
          manageBluetooth: false,
        ),
      ),
    );
    _started = true;
    return stream;
  }

  @override
  Future<void> stop() async {
    if (_disposed || !_started) return;
    _started = false;
    await _recorder.stop();
  }

  @override
  Future<void> cancel() async {
    if (_disposed || !_started) return;
    _started = false;
    await _recorder.cancel();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (_started) await cancel();
    _disposed = true;
    await _recorder.dispose();
  }
}

/// What the user said in one turn.
class CallHeard {
  const CallHeard(this.text, {required this.averageLevel});

  final String text;

  /// Mean microphone level while speaking (0–1), for soft-voice detection.
  final double averageLevel;
}

/// Listens continuously and decides when the user starts and stops talking.
///
/// Speech is a level above the threshold for a short while; the turn ends
/// after a pause. While the companion talks, [companionSpeaking] raises the
/// bar so that only a clear interruption counts.
class CallListener {
  CallListener({
    required this.options,
    required this.settings,
    required this._speakerMode,
  });

  final AsrServiceOptions options;
  final CallSettings settings;
  bool _speakerMode;

  AsrProvider? _asr;
  int _generation = 0;
  bool _closed = false;
  bool muted = false;

  /// True while the companion's voice is playing.
  bool companionSpeaking = false;

  DateTime? _lastTick;
  int _speechMs = 0;
  int _silenceMs = 0;
  int _utteranceMs = 0;
  bool _inSpeech = false;
  double _levelSum = 0;
  int _levelCount = 0;
  bool _finishing = false;
  int _failures = 0;

  /// The user started talking (fires once per utterance).
  void Function()? onSpeechStarted;

  /// The user finished a turn.
  void Function(CallHeard heard)? onHeard;

  /// Recognition failed; the session has been restarted.
  void Function(Object error)? onError;

  /// Microphone level for the UI (0–1).
  double get level => _asr?.soundLevel ?? 0;

  /// Whether the user is mid-utterance right now.
  bool get userSpeaking => _inSpeech;

  /// Time since the user last spoke or the listener last restarted.
  Duration get quietFor => _quietSince == null
      ? Duration.zero
      : DateTime.now().difference(_quietSince!);
  DateTime? _quietSince;

  static const _speechStartMs = 220;
  static const _bargeInStartMs = 380;
  static const _maxUtteranceMs = 45000;

  Future<void> start() => _begin();

  /// Drops whatever was recorded (e.g. the companion's echo) and listens anew,
  /// unless the user is already talking.
  Future<void> restart() async {
    if (_inSpeech || _finishing) return;
    await _begin();
  }

  Future<void> setSpeakerMode(bool value) async {
    if (_speakerMode == value) return;
    _speakerMode = value;
    if (!_inSpeech && !_finishing) await _begin();
  }

  Future<void> _begin() async {
    final generation = ++_generation;
    final previous = _asr;
    _asr = null;
    if (previous != null) {
      previous.removeListener(_onTick);
      try {
        await previous.cancel();
      } catch (_) {}
      previous.dispose();
    }
    if (_closed || generation != _generation) return;
    _resetTurn();
    _quietSince = DateTime.now();
    final speaker = _speakerMode;
    final asr = AsrProvider(
      audioCaptureFactory: () => CallAudioCapture(speakerMode: speaker),
    );
    _asr = asr;
    asr.addListener(_onTick);
    try {
      await asr.start(options);
    } catch (error) {
      if (generation != _generation) return;
      onError?.call(error);
    }
  }

  void _resetTurn() {
    _lastTick = null;
    _speechMs = 0;
    _silenceMs = 0;
    _utteranceMs = 0;
    _inSpeech = false;
    _levelSum = 0;
    _levelCount = 0;
    _finishing = false;
  }

  void _onTick() {
    final asr = _asr;
    if (asr == null || _finishing || _closed) return;
    if (asr.state == AsrSessionState.error) {
      final error = asr.error ?? 'speech recognition failed';
      // Retry a few times; a missing permission or a broken service would
      // otherwise spin forever.
      if (++_failures <= 3) unawaited(_begin());
      onError?.call(error);
      return;
    }
    if (asr.state == AsrSessionState.idle) {
      // System recognition stops on its own after a pause; take what it
      // heard as the turn and listen again.
      final heard = asr.transcript.trim();
      final average = _levelCount == 0 ? 0.0 : _levelSum / _levelCount;
      _finishing = true;
      unawaited(_begin());
      if (heard.isNotEmpty) {
        onHeard?.call(CallHeard(heard, averageLevel: average));
      }
      return;
    }
    if (!asr.isListening) return;
    final now = DateTime.now();
    final last = _lastTick;
    _lastTick = now;
    if (last == null) return;
    final dt = now.difference(last).inMilliseconds.clamp(0, 500);
    if (dt == 0) return;
    final level = muted ? 0.0 : asr.soundLevel;
    final threshold = companionSpeaking
        ? settings.sensitivity.bargeInLevel
        : settings.sensitivity.speechLevel;
    final loud = level >= threshold;

    if (!_inSpeech) {
      _speechMs = loud ? _speechMs + dt : 0;
      final needed = companionSpeaking ? _bargeInStartMs : _speechStartMs;
      if (_speechMs >= needed) {
        _inSpeech = true;
        _silenceMs = 0;
        _utteranceMs = _speechMs;
        _failures = 0;
        onSpeechStarted?.call();
      }
      return;
    }
    _utteranceMs += dt;
    if (level >= settings.sensitivity.speechLevel) {
      _silenceMs = 0;
      _levelSum += level;
      _levelCount++;
    } else {
      _silenceMs += dt;
    }
    if (_silenceMs >= settings.endOfTurnMillis ||
        _utteranceMs >= _maxUtteranceMs) {
      unawaited(_finishTurn());
    }
  }

  Future<void> _finishTurn() async {
    final asr = _asr;
    if (asr == null || _finishing) return;
    _finishing = true;
    final generation = _generation;
    final average = _levelCount == 0 ? 0.0 : _levelSum / _levelCount;
    String text;
    try {
      text = await asr.finish();
    } catch (error) {
      text = '';
      if (generation == _generation) onError?.call(error);
    }
    if (_closed || generation != _generation) return;
    // Listen again right away; recognition of this turn is already done.
    unawaited(_begin());
    if (text.trim().isNotEmpty) {
      onHeard?.call(CallHeard(text.trim(), averageLevel: average));
    }
  }

  Future<void> close() async {
    _closed = true;
    _generation++;
    final asr = _asr;
    _asr = null;
    if (asr != null) {
      asr.removeListener(_onTick);
      try {
        await asr.cancel();
      } catch (_) {}
      asr.dispose();
    }
  }
}
