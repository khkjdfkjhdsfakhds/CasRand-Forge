import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/settings.dart';

void main() {
  test('sequential progress memory defaults to enabled', () {
    expect(Settings.fromJson({}).rememberSequentialProgress, isTrue);
  });

  test('sequential progress memory is persisted in settings JSON', () {
    final settings = Settings.fromJson({
      'remember_sequential_progress': false,
    });

    expect(settings.rememberSequentialProgress, isFalse);
    expect(settings.toJson()['remember_sequential_progress'], isFalse);
  });

  test('legacy batch settings migrate to per-image generation settings', () {
    final settings = Settings.fromJson({
      'batch_count': 4,
      'batch_interval': 12,
      'number_of_requests': 20,
    });

    expect(settings.generationIntervalSec, 12);
    expect(settings.generationCount, 20);

    final json = settings.toJson();
    expect(json['generation_interval'], 12);
    expect(json['generation_count'], 20);
    expect(json.containsKey('batch_count'), isFalse);
    expect(json.containsKey('batch_interval'), isFalse);
    expect(json.containsKey('number_of_requests'), isFalse);
  });

  test('new generation settings take precedence over legacy values', () {
    final settings = Settings.fromJson({
      'generation_interval': 3,
      'generation_count': 5,
      'batch_interval': 12,
      'number_of_requests': 20,
    });

    expect(settings.generationIntervalSec, 3);
    expect(settings.generationCount, 5);
  });
}
