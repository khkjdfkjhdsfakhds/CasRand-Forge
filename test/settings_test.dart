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
}
