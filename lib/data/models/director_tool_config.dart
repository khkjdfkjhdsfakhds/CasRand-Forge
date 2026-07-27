import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:image_size_getter/image_size_getter.dart';

/// Director Tools offered by the current NovelAI site.
/// `declutter-keep-bubbles` is newer than the 0.5.x line, which had six tools.
const toolTypes = [
  DirectorToolType(type: 'bg-removal', name: 'Remove BG'),
  DirectorToolType(type: 'lineart', name: 'Line Art'),
  DirectorToolType(type: 'sketch', name: 'Sketch'),
  DirectorToolType(type: 'colorize', name: 'Colorize'),
  DirectorToolType(type: 'emotion', name: 'Emotion'),
  DirectorToolType(type: 'declutter', name: 'Declutter'),
  DirectorToolType(
    type: 'declutter-keep-bubbles',
    name: 'Declutter (keep bubbles)',
  ),
];

const emotions = [
  'neutral',
  'happy',
  'sad',
  'angry',
  'scared',
  'surprised',
  'tired',
  'excited',
  'nervous',
  'thinking',
  'confused',
  'shy',
  'disgusted',
  'smug',
  'bored',
  'laughing',
  'irritated',
  'aroused',
  'embarrassed',
  'worried',
  'love',
  'determined',
  'hurt',
  'playful',
];

/// Tools that accept a prompt and a defry (prompt strength) value.
const toolsWithPrompt = ['colorize', 'emotion'];

const int maxDefry = 5;

/// Director Tools run against a different endpoint than image generation.
const String augmentImageEndpoint =
    'https://image.novelai.net/ai/augment-image';

class DirectorToolType {
  final String type;
  final String name;

  const DirectorToolType({required this.type, required this.name});
}

class DirectorToolConfig with ChangeNotifier {
  Uint8List? _imageBytes;
  String? _imageB64Cache;

  int width = 0;
  int height = 0;

  String type;

  /// Emotions to pick from; one is chosen at random per request, keeping the
  /// randomised spirit of the rest of the app. Select a single entry for the
  /// deterministic behaviour of the official tool.
  List<String> selectedEmotions;

  int defry;

  bool overrideEnabled;
  String overridePrompt;

  DirectorToolConfig({
    this.type = 'bg-removal',
    List<String>? selectedEmotions,
    this.defry = 0,
    this.overrideEnabled = false,
    this.overridePrompt = '',
  }) : selectedEmotions = selectedEmotions ?? ['neutral'];

  Uint8List? get imageBytes => _imageBytes;
  bool get hasImage => _imageBytes != null;

  String? get imageB64 {
    if (_imageBytes == null) return null;
    _imageB64Cache ??= base64Encode(_imageBytes!);
    return _imageB64Cache;
  }

  bool get withPrompt => toolsWithPrompt.contains(type);

  String get displayName => toolTypes
      .firstWhere((t) => t.type == type, orElse: () => toolTypes.first)
      .name;

  void setImage(Uint8List bytes) {
    final size = ImageSizeGetter.getSize(MemoryInput(bytes));
    width = size.width;
    height = size.height;
    _imageBytes = bytes;
    _imageB64Cache = null;
    notifyListeners();
  }

  void removeImage() {
    _imageBytes = null;
    _imageB64Cache = null;
    width = 0;
    height = 0;
    notifyListeners();
  }

  void setType(String value) {
    if (!toolTypes.any((t) => t.type == value)) return;
    type = value;
    notifyListeners();
  }

  void toggleEmotion(String emotion, bool selected) {
    if (!emotions.contains(emotion)) return;
    if (selected) {
      if (!selectedEmotions.contains(emotion)) selectedEmotions.add(emotion);
    } else if (selectedEmotions.length > 1) {
      selectedEmotions.remove(emotion);
    }
    notifyListeners();
  }

  void setDefry(int value) {
    defry = value.clamp(0, maxDefry);
    notifyListeners();
  }

  void setOverrideEnabled(bool value) {
    overrideEnabled = value;
    notifyListeners();
  }

  void setOverridePrompt(String value) {
    overridePrompt = value;
    notifyListeners();
  }

  /// Request body for [augmentImageEndpoint].
  ///
  /// Only `colorize` and `emotion` carry a prompt and defry; `emotion` encodes
  /// the chosen emotion as `<emotion>;;<extra prompt>`.
  Map<String, dynamic> getPayload() {
    if (!hasImage) {
      throw Exception('Director Tools needs a source image.');
    }
    final payload = <String, dynamic>{
      'req_type': type,
      'width': width,
      'height': height,
      'image': imageB64,
    };
    if (!withPrompt) return payload;

    final extra = overrideEnabled ? overridePrompt : '';
    if (type == 'emotion') {
      final picked = selectedEmotions.isEmpty
          ? 'neutral'
          : selectedEmotions[Random().nextInt(selectedEmotions.length)];
      payload['prompt'] = '$picked;;$extra';
    } else {
      payload['prompt'] = extra;
    }
    payload['defry'] = defry.clamp(0, maxDefry);
    return payload;
  }
}
