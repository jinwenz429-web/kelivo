import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/notification_service.dart';

/// A call the companion placed, ringing until answered, declined or timed out.
@immutable
class IncomingCall {
  const IncomingCall({
    required this.id,
    required this.conversationId,
    required this.assistantName,
    required this.reason,
    required this.at,
  });

  final String id;
  final String conversationId;
  final String assistantName;

  /// Why it called. Shown on the incoming-call card and used to open the call.
  final String reason;
  final DateTime at;
}

/// What the chat records when a call ends without being answered.
const callMissedCard = '📞 未接来电';

/// Quick reasons offered when declining.
const callDeclineReasons = <String>['在忙', '在外面', '想打字聊'];

/// Rings for calls the companion places.
class IncomingCallService extends ChangeNotifier {
  IncomingCallService._();

  static final IncomingCallService instance = IncomingCallService._();

  static const ringDuration = Duration(seconds: 35);
  static const _payloadPrefix = 'incoming-call:';
  static const _notificationId = 7302;
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'kelivo_incoming_call_v1',
    '来电',
    description: '他给你打电话时响铃',
    importance: Importance.max,
    playSound: true,
    sound: UriAndroidNotificationSound('content://settings/system/ringtone'),
    audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
    enableVibration: true,
  );

  IncomingCall? _pending;
  Timer? _timeout;
  Future<void> Function(IncomingCall call)? _onMissed;
  bool _answerRequested = false;

  /// Set by the home page: declined from the notification, no reason given.
  Future<void> Function(IncomingCall call, String note)? onDeclined;

  IncomingCall? get pending => _pending;

  /// True once the user tapped the notification or its answer button.
  bool get answerRequested => _answerRequested;

  Future<void> ring(
    IncomingCall call, {
    required Future<void> Function(IncomingCall call) onMissed,
  }) async {
    _clear();
    _pending = call;
    _onMissed = onMissed;
    _timeout = Timer(ringDuration, _missed);
    notifyListeners();
    await _showNotification(call);
  }

  static IncomingCall create({
    required String conversationId,
    required String assistantName,
    required String reason,
  }) => IncomingCall(
    id: const Uuid().v4(),
    conversationId: conversationId,
    assistantName: assistantName,
    reason: reason,
    at: DateTime.now(),
  );

  /// Takes the ringing call to answer it.
  IncomingCall? answer() {
    final call = _pending;
    _clear();
    notifyListeners();
    return call;
  }

  /// Declines; the note travels back to the companion.
  Future<void> decline(String note) async {
    final call = _pending;
    _clear();
    notifyListeners();
    if (call != null) await onDeclined?.call(call, note);
  }

  /// Routes taps on the incoming-call notification. Returns false for other
  /// notifications.
  bool handleNotificationResponse(NotificationResponse response) {
    final payload = response.payload ?? '';
    if (!payload.startsWith(_payloadPrefix)) return false;
    final id = payload.substring(_payloadPrefix.length);
    if (_pending?.id != id) return true; // already over
    if (response.actionId == 'decline') {
      unawaited(decline(''));
    } else {
      _answerRequested = true;
      notifyListeners();
    }
    return true;
  }

  void _missed() {
    final call = _pending;
    final onMissed = _onMissed;
    _clear();
    notifyListeners();
    if (call != null && onMissed != null) unawaited(onMissed(call));
  }

  void _clear() {
    _timeout?.cancel();
    _timeout = null;
    _pending = null;
    _onMissed = null;
    _answerRequested = false;
    unawaited(_cancelNotification());
  }

  Future<void> _showNotification(IncomingCall call) async {
    if (!Platform.isAndroid) return;
    final plugin = await NotificationService.pluginForCalls(_channel);
    if (plugin == null) return;
    final why = call.reason.trim();
    await plugin.show(
      _notificationId,
      '${call.assistantName} 来电',
      why.isEmpty ? '想和你说说话' : why,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          visibility: NotificationVisibility.public,
          timeoutAfter: ringDuration.inMilliseconds,
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          // FLAG_INSISTENT: the ringtone repeats until answered or cancelled.
          additionalFlags: Int32List.fromList(<int>[4]),
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              'decline',
              '拒接',
              showsUserInterface: true,
            ),
            AndroidNotificationAction('answer', '接听', showsUserInterface: true),
          ],
        ),
      ),
      payload: '$_payloadPrefix${call.id}',
    );
  }

  Future<void> _cancelNotification() async {
    if (!Platform.isAndroid) return;
    final plugin = await NotificationService.pluginForCalls(_channel);
    await plugin?.cancel(_notificationId);
  }
}
