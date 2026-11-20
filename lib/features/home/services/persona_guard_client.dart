import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/agency/agency_settings.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_helpers.dart';

/// Talks to a Pawwake gateway about persona drift ("出戏").
///
/// Every reply request carries `X-Persona-Guard-Request-Id` (the reply's
/// message id). Pawwake records whether the streamed reply broke character
/// under that id; after the reply finishes Kelivo asks, and regenerates it
/// once if told to. The retry carries the original id with stage
/// `regenerate` so Pawwake attaches it to the same round instead of storing
/// the user's message twice. Providers other than Pawwake answer 404 and
/// nothing happens.
class PersonaGuardClient {
  const PersonaGuardClient._();

  static final Map<String, String> _pendingRetryByConversation = {};
  static final Map<String, String> _retryOrigin = {};
  static final RegExp _validId = RegExp(r'^[A-Za-z0-9-]{8,64}$');

  static bool get enabled =>
      AgencySettingsStore.instance.value.regenerateOnDrift;

  /// Headers for the request that generates [messageId].
  static Map<String, String> headersFor({
    required String conversationId,
    required String messageId,
  }) {
    if (!enabled) return const {};
    final origin = _pendingRetryByConversation.remove(conversationId);
    if (origin != null) _retryOrigin[messageId] = origin;
    final requestId = origin ?? messageId;
    if (!_validId.hasMatch(requestId)) return const {};
    return {
      'X-Persona-Guard-Request-Id': requestId,
      'X-Persona-Guard-Stage': origin == null ? 'initial' : 'regenerate',
    };
  }

  /// A retry is never retried again.
  static bool isRetry(String messageId) => _retryOrigin.containsKey(messageId);

  /// Call right before regenerating [originMessageId] because it drifted.
  static void markRetry({
    required String conversationId,
    required String originMessageId,
  }) => _pendingRetryByConversation[conversationId] = originMessageId;

  static void clearRetry(String conversationId) =>
      _pendingRetryByConversation.remove(conversationId);

  /// Asks the gateway whether [messageId]'s reply should be regenerated.
  static Future<bool> shouldRegenerate({
    required ProviderConfig config,
    required String modelId,
    required String messageId,
    http.Client? client,
  }) async {
    if (!enabled || !_validId.hasMatch(messageId)) return false;
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base/persona-guard/verdicts/$messageId');
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) {
      return false;
    }
    final http.Client http0 = client ?? http.Client();
    try {
      final response = await http0
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer ${apiKeyForRequest(config, modelId)}',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return false;
      final json = jsonDecode(response.body);
      return json is Map && json['regenerate'] == true;
    } catch (_) {
      return false;
    } finally {
      if (client == null) http0.close();
    }
  }
}
