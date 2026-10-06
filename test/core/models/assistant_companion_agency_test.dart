import 'package:Kelivo/core/models/assistant.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('companion agency defaults off for existing assistants', () {
    final assistant = Assistant.fromJson(const <String, dynamic>{
      'id': 'a',
      'name': 'A',
    });

    expect(assistant.companionAgencyEnabled, isFalse);
  });

  test('companion agency survives serialization and copyWith', () {
    const assistant = Assistant(
      id: 'a',
      name: 'A',
      companionAgencyEnabled: true,
    );

    final decoded = Assistant.fromJson(assistant.toJson());
    expect(decoded.companionAgencyEnabled, isTrue);
    expect(
      decoded.copyWith(companionAgencyEnabled: false).companionAgencyEnabled,
      isFalse,
    );
  });
}
