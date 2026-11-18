import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:Kelivo/core/agency/agency_settings.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/home/services/persona_guard_client.dart';

void main() {
  const id = '6f1c2a3b-0000-4000-8000-123456789abc';

  setUpAll(
    () => AgencySettingsStore.instance.update(
      const AgencySettings(regenerateOnDrift: true),
    ),
  );
  tearDownAll(
    () => AgencySettingsStore.instance.update(const AgencySettings()),
  );

  test('nothing is sent when the switch is off', () async {
    await AgencySettingsStore.instance.update(const AgencySettings());
    expect(
      PersonaGuardClient.headersFor(conversationId: 'c0', messageId: id),
      isEmpty,
    );
    await AgencySettingsStore.instance.update(
      const AgencySettings(regenerateOnDrift: true),
    );
  });

  test('first request is initial; a marked retry carries the origin id', () {
    expect(PersonaGuardClient.headersFor(conversationId: 'c1', messageId: id), {
      'X-Persona-Guard-Request-Id': id,
      'X-Persona-Guard-Stage': 'initial',
    });
    PersonaGuardClient.markRetry(conversationId: 'c1', originMessageId: id);
    const retryId = '7a2b3c4d-1111-4000-8000-abcdefabcdef';
    expect(
      PersonaGuardClient.headersFor(conversationId: 'c1', messageId: retryId),
      {'X-Persona-Guard-Request-Id': id, 'X-Persona-Guard-Stage': 'regenerate'},
    );
    expect(PersonaGuardClient.isRetry(retryId), isTrue);
    expect(PersonaGuardClient.isRetry(id), isFalse);
    // The pending mark is consumed by the retry it was meant for.
    expect(
      PersonaGuardClient.headersFor(
        conversationId: 'c1',
        messageId: '8b3c4d5e-2222-4000-8000-abcdefabcdef',
      )['X-Persona-Guard-Stage'],
      'initial',
    );
  });

  test('asks the gateway and follows its answer', () async {
    final config = ProviderConfig(
      id: 'pawwake',
      enabled: true,
      name: 'pawwake',
      apiKey: 'secret',
      baseUrl: 'https://pawwake.example/v1/',
    );
    late http.Request seen;
    Future<bool> ask(int status, String body) =>
        PersonaGuardClient.shouldRegenerate(
          config: config,
          modelId: 'gemini',
          messageId: id,
          client: MockClient((request) async {
            seen = request;
            return http.Response(body, status);
          }),
        );

    expect(
      await ask(200, '{"status":"CONFIRMED_DRIFT","regenerate":true}'),
      isTrue,
    );
    expect(
      seen.url.toString(),
      'https://pawwake.example/v1/persona-guard/verdicts/$id',
    );
    expect(seen.headers['Authorization'], 'Bearer secret');
    expect(await ask(200, '{"status":"NORMAL","regenerate":false}'), isFalse);
    expect(await ask(404, 'not found'), isFalse);
    expect(await ask(200, 'oops'), isFalse);
  });
}
