import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/models/user_input_validation.dart';

void main() {
  group('manual generation size validation', () {
    test('normalizes valid dimensions onto the 64 pixel grid', () {
      final result = validateManualGenerationSize('833', '1217');

      expect(result.value, const GenerationSize(width: 896, height: 1280));
      expect(result.error, isNull);
    });

    test('rejects non-positive, overflowing, and over-area dimensions', () {
      expect(
        validateManualGenerationSize('0', '1024').error,
        UserInputError.nonPositiveDimension,
      );
      expect(
        validateManualGenerationSize('-64', '1024').error,
        UserInputError.nonPositiveDimension,
      );
      expect(
        validateManualGenerationSize('999999999999999999999999', '64').error,
        UserInputError.dimensionOutOfRange,
      );
      expect(
        validateManualGenerationSize('2048', '2048').error,
        UserInputError.dimensionOutOfRange,
      );
    });

    test('rejects malformed dimensions without changing their meaning', () {
      expect(
        validateManualGenerationSize('12.5', '1024').error,
        UserInputError.invalidDimension,
      );
      expect(
        validateManualGenerationSize('', '1024').error,
        UserInputError.invalidDimension,
      );
    });
  });

  group('proxy validation', () {
    test('accepts empty routes, whitespace, hostnames, and bounded IPv4', () {
      expect(validateProxyAddress('').value, '');
      expect(validateProxyAddress('   ').value, '');
      expect(validateProxyAddress(' localhost:7890 ').value, 'localhost:7890');
      expect(validateProxyAddress('proxy.example.test:443').value,
          'proxy.example.test:443');
      expect(validateProxyAddress('255.255.255.255:65535').value,
          '255.255.255.255:65535');
    });

    test('rejects invalid IPv4 octets, ports, and hostnames', () {
      expect(
        validateProxyAddress('256.1.1.1:7890').error,
        UserInputError.invalidProxyHost,
      );
      expect(
        validateProxyAddress('127.0.0.1:0').error,
        UserInputError.invalidProxyPort,
      );
      expect(
        validateProxyAddress('127.0.0.1:65536').error,
        UserInputError.invalidProxyPort,
      );
      expect(
        validateProxyAddress('-proxy.example:443').error,
        UserInputError.invalidProxyHost,
      );
      expect(
        validateProxyAddress('https://proxy.example:443').error,
        UserInputError.invalidProxyAddress,
      );
    });
  });
}
