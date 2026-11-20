import 'dart:async';
import 'dart:io' as io;

import 'package:audioplayers/audioplayers.dart';
import 'package:path/path.dart' as p;

import '../../core/services/tts/network_tts.dart';
import '../../core/providers/tts_provider.dart'
    show ttsAudioFileExtensionForMime;
import 'call_settings.dart';

/// One sentence of the companion's reply, synthesized ahead and played in order.
class CallUtterance {
  CallUtterance._(this.speech, this.display, this.audio);

  final String speech;
  final String display;
  final Future<io.File> audio;

  /// Set once playback of this sentence has started.
  bool started = false;
}

/// Reads the companion's lines during a call.
///
/// Sentences are synthesized as soon as they arrive, so the next one is
/// usually ready when the current one ends. [stop] cuts playback at once and
/// drops whatever was still queued.
class CallVoice {
  CallVoice({
    required this.service,
    required this.audioDirectory,
    required this.speakerMode,
  });

  /// The TTS service as configured, with the call's model already applied.
  final TtsServiceOptions service;

  /// Where synthesized audio is kept for the call record.
  final io.Directory audioDirectory;

  final AudioPlayer _player = AudioPlayer();
  final List<CallUtterance> _queue = <CallUtterance>[];
  StreamSubscription<void>? _completeSub;
  Completer<void>? _playing;
  int _generation = 0;
  int _fileIndex = 0;
  bool _pumping = false;

  /// Hands-free (echo cancelled) rather than headphones.
  bool speakerMode;
  bool _disposed = false;

  /// Called when a sentence starts playing.
  void Function(CallUtterance utterance)? onStarted;

  /// Called when the queue has played out (not after [stop]).
  void Function()? onDrained;

  /// Called when a sentence could not be synthesized or played.
  void Function(Object error)? onError;

  bool get isSpeaking => _pumping;

  /// Applies an override of the ElevenLabs model for calls.
  static TtsServiceOptions withCallModel(
    TtsServiceOptions service,
    CallVoiceModel model,
  ) {
    final modelId = model.elevenLabsModelId;
    if (modelId == null || service.kind != NetworkTtsKind.elevenlabs) {
      return service;
    }
    final json = service.toJson()..['modelId'] = modelId;
    return TtsServiceOptions.fromJson(json);
  }

  /// Whether the service reads ElevenLabs audio tags.
  static bool readsAudioTags(TtsServiceOptions service) =>
      service.kind == NetworkTtsKind.elevenlabs &&
      (service.toJson()['modelId'] ?? '').toString() == 'eleven_v3';

  Future<void> prepare() async {
    await audioDirectory.create(recursive: true);
    await _applyAudioContext();
    _completeSub = _player.onPlayerComplete.listen((_) {
      final playing = _playing;
      if (playing != null && !playing.isCompleted) playing.complete();
    });
  }

  Future<void> setSpeakerMode(bool value) async {
    if (speakerMode == value) return;
    speakerMode = value;
    await _applyAudioContext();
  }

  /// Speaker mode talks like a hands-free phone call so the microphone's echo
  /// cancellation can hear what is playing. Headphone mode plays as media so
  /// Bluetooth earbuds keep full quality.
  Future<void> _applyAudioContext() async {
    if (!io.Platform.isAndroid) return;
    await _player.setAudioContext(
      AudioContext(
        android: speakerMode
            ? const AudioContextAndroid(
                isSpeakerphoneOn: true,
                audioMode: AndroidAudioMode.inCommunication,
                contentType: AndroidContentType.speech,
                usageType: AndroidUsageType.voiceCommunication,
                audioFocus: AndroidAudioFocus.gain,
                stayAwake: true,
              )
            : const AudioContextAndroid(
                contentType: AndroidContentType.speech,
                usageType: AndroidUsageType.media,
                audioFocus: AndroidAudioFocus.gain,
                stayAwake: true,
              ),
      ),
    );
  }

  Future<void> setVolume(double volume) async {
    try {
      await _player.setVolume(volume);
    } catch (_) {}
  }

  /// Queues a sentence. Synthesis starts right away.
  CallUtterance say(String speech, String display) {
    final generation = _generation;
    final audio = _synthesize(speech, generation);
    audio.ignore();
    final utterance = CallUtterance._(speech, display, audio);
    _queue.add(utterance);
    unawaited(_pump(generation));
    return utterance;
  }

  Future<io.File> _synthesize(String text, int generation) async {
    final result = await NetworkTtsService.synthesize(
      options: service,
      text: text,
      cancelled: () => generation != _generation || _disposed,
    );
    if (result.bytes.isEmpty) throw StateError('TTS returned empty audio');
    final file = io.File(
      p.join(
        audioDirectory.path,
        'line_${_fileIndex++}.${ttsAudioFileExtensionForMime(result.mime)}',
      ),
    );
    await file.writeAsBytes(result.bytes, flush: true);
    return file;
  }

  Future<void> _pump(int generation) async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty && generation == _generation && !_disposed) {
        final next = _queue.first;
        io.File file;
        try {
          file = await next.audio;
        } catch (error) {
          if (generation != _generation) return;
          _queue.remove(next);
          onError?.call(error);
          continue;
        }
        if (generation != _generation || _disposed) return;
        next.started = true;
        onStarted?.call(next);
        final playing = _playing = Completer<void>();
        try {
          await _player.play(DeviceFileSource(file.path));
          await playing.future;
        } catch (error) {
          if (generation == _generation) onError?.call(error);
        }
        if (generation != _generation) return;
        _queue.remove(next);
      }
      if (generation == _generation && !_disposed) onDrained?.call();
    } finally {
      if (generation == _generation) _pumping = false;
    }
  }

  /// Stops at once and forgets everything queued. Returns the sentences that
  /// had started playing since the last stop.
  Future<void> stop() async {
    _generation++;
    _queue.clear();
    _pumping = false;
    final playing = _playing;
    if (playing != null && !playing.isCompleted) playing.complete();
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// Plays one saved file (for replay from the call record).
  static Future<void> playFile(AudioPlayer player, String path) =>
      player.play(DeviceFileSource(path));

  Future<void> dispose() async {
    _disposed = true;
    await stop();
    await _completeSub?.cancel();
    if (io.Platform.isAndroid) {
      // Leave the phone in normal audio mode for every other app.
      try {
        await _player.setAudioContext(
          AudioContext(android: const AudioContextAndroid()),
        );
      } catch (_) {}
    }
    await _player.dispose();
  }
}
