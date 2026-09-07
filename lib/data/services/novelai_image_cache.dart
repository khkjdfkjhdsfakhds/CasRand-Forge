import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class NovelAiImageCache {
  final Map<String, _ImageCacheSession> _sessions = {};

  static bool supports(Uri endpoint) {
    if (endpoint.path != '/ai/generate-image') return false;
    final host = endpoint.host.toLowerCase();
    return host == 'image.novelai.net' ||
        RegExp(r'^image-[a-z0-9-]+\.novelai\.net$').hasMatch(host);
  }

  Future<PreparedImageRequest> prepare(
    Map<String, dynamic> originalPayload,
    String sessionKey,
  ) async {
    final payload = _copyJsonMap(originalPayload);
    final parameters = payload['parameters'];
    if (parameters is! Map<String, dynamic>) {
      return PreparedImageRequest(payload);
    }

    final session = _sessions.putIfAbsent(sessionKey, _ImageCacheSession.new);
    final sources = _imageSources(parameters);
    if (sources.isEmpty) return PreparedImageRequest(payload);
    final keys = await compute(_deriveCacheKeys, (
      secret: session.secret,
      imageData: sources.map((source) => source.data).toList(),
    ));
    final uploadedKeys = <String>{};
    for (var index = 0; index < sources.length; index++) {
      sources[index].apply(
        parameters,
        keys[index],
        session.knownKeys,
        uploadedKeys,
      );
    }
    return PreparedImageRequest(
      payload,
      uploadedKeys: uploadedKeys,
      imageSourceCount: sources.length,
    );
  }

  void markUploaded(String sessionKey, Iterable<String> keys) {
    _sessions[sessionKey]?.knownKeys.addAll(keys);
  }

  void invalidate(String sessionKey, Iterable<String> keys) {
    _sessions[sessionKey]?.knownKeys.removeAll(keys);
  }

  void removeSessionsWhere(bool Function(String sessionKey) test) {
    _sessions.removeWhere((sessionKey, _) => test(sessionKey));
  }

  int get sessionCount => _sessions.length;

  void clear() => _sessions.clear();
}

class PreparedImageRequest {
  final Map<String, dynamic> payload;
  final Set<String> uploadedKeys;
  final int imageSourceCount;

  PreparedImageRequest(
    this.payload, {
    this.uploadedKeys = const {},
    this.imageSourceCount = 0,
  });
}

List<_ImageSource> _imageSources(Map<String, dynamic> parameters) {
  final sources = <_ImageSource>[];
  void addImage(String dataField, String keyField) {
    final data = parameters[dataField];
    if (data is String && data.isNotEmpty) {
      sources.add(_SingleImageSource(dataField, keyField, data));
    }
  }

  void addImages(String dataField, String cachedField) {
    final data = parameters[dataField];
    if (data is! List || data.isEmpty || data.any((item) => item is! String)) {
      return;
    }
    for (var index = 0; index < data.length; index++) {
      sources.add(_ArrayImageSource(
        dataField,
        cachedField,
        index,
        data[index] as String,
        data.length,
      ));
    }
  }

  addImage('image', 'image_cache_secret_key');
  addImage('mask', 'mask_cache_secret_key');
  addImage('reference_image', 'reference_image_cache_secret_key');
  addImages('reference_image_multiple', 'reference_image_multiple_cached');
  addImages('director_reference_images', 'director_reference_images_cached');
  return sources;
}

sealed class _ImageSource {
  final String data;

  const _ImageSource(this.data);

  void apply(
    Map<String, dynamic> parameters,
    String key,
    Set<String> knownKeys,
    Set<String> uploadedKeys,
  );
}

class _SingleImageSource extends _ImageSource {
  final String dataField;
  final String keyField;

  const _SingleImageSource(this.dataField, this.keyField, super.data);

  @override
  void apply(
    Map<String, dynamic> parameters,
    String key,
    Set<String> knownKeys,
    Set<String> uploadedKeys,
  ) {
    parameters[keyField] = key;
    if (knownKeys.contains(key)) {
      parameters.remove(dataField);
    } else {
      uploadedKeys.add(key);
    }
  }
}

class _ArrayImageSource extends _ImageSource {
  final String dataField;
  final String cachedField;
  final int index;
  final int length;

  const _ArrayImageSource(
    this.dataField,
    this.cachedField,
    this.index,
    super.data,
    this.length,
  );

  @override
  void apply(
    Map<String, dynamic> parameters,
    String key,
    Set<String> knownKeys,
    Set<String> uploadedKeys,
  ) {
    final cached = parameters.putIfAbsent(
      cachedField,
      () => List<Map<String, dynamic>>.filled(length, const {}),
    ) as List;
    if (knownKeys.contains(key)) {
      cached[index] = <String, dynamic>{'cache_secret_key': key};
    } else {
      uploadedKeys.add(key);
      cached[index] = <String, dynamic>{
        'cache_secret_key': key,
        'data': data,
      };
    }
    if (index == length - 1) parameters.remove(dataField);
  }
}

List<String> _deriveCacheKeys(
  ({List<int> secret, List<String> imageData}) input,
) {
  final hmac = Hmac(sha256, input.secret);
  return input.imageData
      .map((data) => hmac.convert(utf8.encode(data)).toString())
      .toList();
}

Map<String, dynamic> _copyJsonMap(Map<String, dynamic> source) =>
    source.map((key, value) => MapEntry(key, _copyJsonValue(value)));

dynamic _copyJsonValue(dynamic value) {
  if (value is Map<String, dynamic>) return _copyJsonMap(value);
  if (value is List) return value.map(_copyJsonValue).toList();
  return value;
}

class _ImageCacheSession {
  final List<int> secret;
  final Set<String> knownKeys = {};

  _ImageCacheSession() : secret = _randomSecret();
}

List<int> _randomSecret() {
  final random = Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256), growable: false);
}
