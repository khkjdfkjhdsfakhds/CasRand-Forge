import 'package:nai_casrand/data/models/generation_size.dart';
import 'package:nai_casrand/data/use_cases/i2i_request_size.dart';

enum UserInputError {
  invalidDimension,
  nonPositiveDimension,
  dimensionOutOfRange,
  invalidProxyAddress,
  invalidProxyHost,
  invalidProxyPort,
}

class UserInputValidationResult<T> {
  final T? value;
  final UserInputError? error;

  const UserInputValidationResult.valid(this.value) : error = null;
  const UserInputValidationResult.invalid(this.error) : value = null;

  bool get isValid => error == null;
}

UserInputValidationResult<GenerationSize> validateManualGenerationSize(
  String widthText,
  String heightText,
) {
  final width = BigInt.tryParse(widthText.trim());
  final height = BigInt.tryParse(heightText.trim());
  if (width == null || height == null) {
    return const UserInputValidationResult.invalid(
      UserInputError.invalidDimension,
    );
  }
  if (width <= BigInt.zero || height <= BigInt.zero) {
    return const UserInputValidationResult.invalid(
      UserInputError.nonPositiveDimension,
    );
  }

  final step = BigInt.from(novelAiSizeStep);
  final normalizedWidth = ((width + step - BigInt.one) ~/ step) * step;
  final normalizedHeight = ((height + step - BigInt.one) ~/ step) * step;
  final maxPixels = BigInt.from(novelAiGenerationMaxPixels);
  if (normalizedWidth > maxPixels ||
      normalizedHeight > maxPixels ||
      normalizedWidth * normalizedHeight > maxPixels) {
    return const UserInputValidationResult.invalid(
      UserInputError.dimensionOutOfRange,
    );
  }

  return UserInputValidationResult.valid(GenerationSize(
    width: normalizedWidth.toInt(),
    height: normalizedHeight.toInt(),
  ));
}

UserInputValidationResult<String> validateProxyAddress(String input) {
  final value = input.trim();
  if (value.isEmpty) return const UserInputValidationResult.valid('');

  final separator = value.lastIndexOf(':');
  if (separator <= 0 || separator != value.indexOf(':')) {
    return const UserInputValidationResult.invalid(
      UserInputError.invalidProxyAddress,
    );
  }
  final host = value.substring(0, separator);
  final portText = value.substring(separator + 1);
  if (!RegExp(r'^\d+$').hasMatch(portText)) {
    return const UserInputValidationResult.invalid(
      UserInputError.invalidProxyPort,
    );
  }
  final port = int.tryParse(portText);
  if (port == null || port < 1 || port > 65535) {
    return const UserInputValidationResult.invalid(
      UserInputError.invalidProxyPort,
    );
  }
  if (!_isValidProxyHost(host)) {
    return const UserInputValidationResult.invalid(
      UserInputError.invalidProxyHost,
    );
  }
  return UserInputValidationResult.valid('$host:$port');
}

bool _isValidProxyHost(String host) {
  if (host.isEmpty || host.length > 253) return false;
  if (RegExp(r'^[0-9.]+$').hasMatch(host)) {
    final octets = host.split('.');
    return octets.length == 4 &&
        octets.every((octet) {
          if (octet.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(octet)) {
            return false;
          }
          final value = int.parse(octet);
          return value >= 0 && value <= 255;
        });
  }

  final labels = host.split('.');
  final labelPattern =
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
  return labels.every(labelPattern.hasMatch);
}
