import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/agent_control/agent_generation_port.dart';
import 'package:nai_casrand/agent_control/json_edit.dart';
import 'package:nai_casrand/data/models/displayed_image_size.dart';
import 'package:nai_casrand/data/models/generation_profile.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';

/// A failure reported back to the agent. [code] is stable and machine
/// readable; [status] is the HTTP status the REST endpoint uses.
class AgentControlException implements Exception {
  final String code;
  final String message;
  final int status;

  const AgentControlException(this.code, this.message, {this.status = 400});

  @override
  String toString() => '$code: $message';
}

class AgentImage {
  final Uint8List bytes;
  final String mimeType;

  const AgentImage(this.bytes, this.mimeType);
}

class AgentToolResult {
  final Object? data;
  final List<AgentImage> images;

  const AgentToolResult(this.data, {this.images = const []});
}

typedef AgentToolHandler = Future<AgentToolResult> Function(
  Map<String, dynamic> arguments,
);

class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  /// Mutating tools are serialized, refused during generation where noted,
  /// and announced in the app so the user can see what an agent changed.
  final bool mutates;
  final AgentToolHandler handler;

  const AgentTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.mutates = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// Settings an agent can never read or change: credentials, and the request
/// destinations that would decide where those credentials are sent.
const protectedSettingKeys = <String>{
  'api_key',
  'api_tokens',
  'parallel_api_enabled',
  'api_base_url',
  'proxy',
};

String sniffImageMimeType(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'image/webp';
  }
  return 'application/octet-stream';
}

Uint8List _createJpegPreview((Uint8List, int) request) {
  final (bytes, longestEdge) = request;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('The image could not be decoded.');
  }
  final source = img.bakeOrientation(decoded);
  final landscape = source.width >= source.height;
  final needsResize = (landscape ? source.width : source.height) > longestEdge;
  final preview = needsResize
      ? img.copyResize(
          source,
          width: landscape ? longestEdge : null,
          height: landscape ? null : longestEdge,
          interpolation: img.Interpolation.average,
        )
      : source;
  return Uint8List.fromList(img.encodeJpg(preview, quality: 85));
}

Uint8List _createI2iPreview(Uint8List bytes) => _createPngPreview((bytes, 512));

Uint8List _createPngPreview((Uint8List, int) request) {
  final (bytes, longestEdge) = request;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('The image could not be decoded.');
  }
  final source = img.bakeOrientation(decoded);
  final landscape = source.width >= source.height;
  final preview = img.copyResize(
    source,
    width: landscape ? longestEdge : null,
    height: landscape ? null : longestEdge,
    interpolation: img.Interpolation.linear,
  );
  return Uint8List.fromList(img.encodePng(preview, level: 3));
}

(int, int) _imageSize(Uint8List bytes) {
  final size = displayedImageSize(bytes);
  return (size.width.round(), size.height.round());
}

/// Every operation an agent can perform. The MCP and REST endpoints are thin
/// transports over [tools]; all edits go through [PayloadConfig] and
/// [ConfigService] exactly like the app's own pages.
class AgentControlService {
  AgentControlService({
    required PayloadConfig Function() payloadConfig,
    required ConfigService Function() configService,
    required AgentGenerationPort Function() generation,
    void Function(String action)? onActivity,
    VoidCallback? onConfigReplaced,
    Duration pollInterval = const Duration(milliseconds: 250),
  })  : _payloadConfig = payloadConfig,
        _configService = configService,
        _generation = generation,
        _onActivity = onActivity,
        _onConfigReplaced = onConfigReplaced,
        _pollInterval = pollInterval;

  final PayloadConfig Function() _payloadConfig;
  final ConfigService Function() _configService;
  final AgentGenerationPort Function() _generation;
  final void Function(String action)? _onActivity;
  final VoidCallback? _onConfigReplaced;
  final Duration _pollInterval;

  final Expando<int> _resultIds = Expando('agentResultId');
  int _nextResultId = 1;
  Set<Object>? _runBaseline;
  bool _starting = false;
  Future<void> _mutationTail = Future<void>.value();

  PayloadConfig get _config => _payloadConfig();
  ConfigService get _store => _configService();
  AgentGenerationPort get _port => _generation();

  late final List<AgentTool> tools = _buildTools();
  late final Map<String, AgentTool> _toolsByName = {
    for (final tool in tools) tool.name: tool,
  };

  /// Runs [name] with [arguments]. Mutating tools run one at a time.
  Future<AgentToolResult> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final tool = _toolsByName[name];
    if (tool == null) {
      throw AgentControlException(
        'unknown_tool',
        "Unknown tool '$name'.",
        status: 404,
      );
    }
    if (!tool.mutates) return tool.handler(arguments);
    final completer = Completer<AgentToolResult>();
    final previous = _mutationTail;
    _mutationTail = completer.future.then<void>((_) {}, onError: (_) {});
    await previous;
    try {
      final result = await tool.handler(arguments);
      _onActivity?.call(name);
      completer.complete(result);
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  // ---------------------------------------------------------------------------
  // Shared helpers

  bool get _generatorOccupied =>
      _starting || _port.isActive || _port.isStopping || _port.isBusy;

  void _requireIdle() {
    if (_generatorOccupied) {
      throw const AgentControlException(
        'generation_in_progress',
        'Generation is running. Call stop_generation (or wait_for_generation) '
            'before changing the configuration.',
        status: 409,
      );
    }
  }

  static Map<String, dynamic> _object(Object? value, String name) {
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    throw AgentControlException('invalid_argument', '$name must be an object.');
  }

  static String _string(Map<String, dynamic> args, String name) {
    final value = args[name];
    if (value is String && value.trim().isNotEmpty) return value;
    throw AgentControlException(
      'invalid_argument',
      '$name must be a non-empty string.',
    );
  }

  static int? _optionalInt(Map<String, dynamic> args, String name,
      {int min = 0, int? max}) {
    final value = args[name];
    if (value == null) return null;
    final number = value is num ? value : num.tryParse(value.toString());
    if (number == null || number != number.roundToDouble()) {
      throw AgentControlException(
          'invalid_argument', '$name must be an integer.');
    }
    final integer = number.toInt();
    if (integer < min || (max != null && integer > max)) {
      throw AgentControlException(
        'invalid_argument',
        '$name must be between $min and ${max ?? 'unbounded'}.',
      );
    }
    return integer;
  }

  static double? _optionalDouble(Map<String, dynamic> args, String name) {
    final value = args[name];
    if (value == null) return null;
    final number = value is num ? value : num.tryParse(value.toString());
    if (number == null) {
      throw AgentControlException(
          'invalid_argument', '$name must be a number.');
    }
    return number.toDouble();
  }

  /// The current configuration without credentials or request destinations.
  Map<String, dynamic> _shareableConfig([Map<String, dynamic>? source]) {
    final json = source == null
        ? _config.toShareableJson()
        : PayloadConfig.fromJson(source).toShareableJson();
    final settings = json['settings'];
    if (settings is Map) {
      for (final key in protectedSettingKeys) {
        settings.remove(key);
      }
    }
    return Map<String, dynamic>.from(deepCopyJson(json) as Map);
  }

  /// Builds a full candidate from an agent-edited shareable document while
  /// keeping this device's credentials and request destinations.
  Map<String, dynamic> _candidateFrom(Map<String, dynamic> edited) {
    final settings = edited['settings'];
    if (settings is Map) {
      final touched = protectedSettingKeys.where(settings.containsKey).toList();
      if (touched.isNotEmpty) {
        throw AgentControlException(
          'protected_setting',
          'These settings can only be changed in the app: '
              '${touched.join(', ')}.',
          status: 403,
        );
      }
    }
    try {
      _store.validateConfigJson(edited);
      final live = _config.settings;
      final candidate = PayloadConfig.fromJson(_config.toJson())
        ..loadShareableJson(edited);
      candidate.settings
        ..apiBaseUrl = live.apiBaseUrl
        ..proxy = live.proxy;
      final candidateJson = candidate.toJson();
      _store.validateConfigJson(candidateJson);
      return candidateJson;
    } on ConfigValidationException catch (error) {
      throw AgentControlException('invalid_config', error.message);
    } on AgentControlException {
      rethrow;
    } catch (error) {
      throw AgentControlException('invalid_config', '$error');
    }
  }

  Future<void> _applyCandidate(Map<String, dynamic> candidate) async {
    await _store.saveConfig(candidate);
    _config.loadJson(candidate);
    _config.notifyExternalChange();
    _onConfigReplaced?.call();
  }

  Map<String, dynamic> _currentSchemeInfo() => {
        'index': _config.currentPromptSchemeIndex,
        'name': _config.currentPromptScheme.name,
        'count': _config.promptSchemes.length,
      };

  /// The scheme list and selection must keep matching the top-level document,
  /// which is always the current scheme, so a generic edit cannot change them.
  void _requireSchemesUntouched(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    List<Object?> names(Map<String, dynamic> json) {
      final schemes = json['prompt_schemes'];
      if (schemes is! List) return const [];
      return [for (final item in schemes) item is Map ? item['name'] : null];
    }

    final currentIndex = before['current_prompt_scheme'] as int;
    final schemes = after['prompt_schemes'];
    final beforeNames = names(before);
    final afterNames = names(after);
    final currentEntry = schemes is List && currentIndex < schemes.length
        ? schemes[currentIndex]
        : null;
    if (after['current_prompt_scheme'] != currentIndex ||
        !listEquals(beforeNames, afterNames) ||
        currentEntry is! Map ||
        currentEntry.length != 1) {
      throw const AgentControlException(
        'use_scheme_tools',
        'Use switch_prompt_scheme, create_prompt_scheme, rename_prompt_scheme '
            'or delete_prompt_scheme to change schemes. The current scheme is '
            'edited at the top level of the document; other schemes under '
            '/prompt_schemes/<index>.',
      );
    }
  }

  int _schemeIndex(Map<String, dynamic> args) {
    final schemes = _config.promptSchemes;
    final index = _optionalInt(args, 'index');
    if (index != null) {
      if (index >= schemes.length) {
        throw AgentControlException(
          'not_found',
          'There is no prompt scheme at index $index.',
          status: 404,
        );
      }
      return index;
    }
    final name = _string(args, 'name').trim();
    final matches = [
      for (final (i, scheme) in schemes.indexed)
        if (scheme.name == name) i,
    ];
    if (matches.isEmpty) {
      throw AgentControlException(
        'not_found',
        "No prompt scheme is named '$name'.",
        status: 404,
      );
    }
    if (matches.length > 1) {
      throw AgentControlException(
        'ambiguous',
        "Several prompt schemes are named '$name'; pass index instead.",
      );
    }
    return matches.single;
  }

  void _requireSchemeName(String name, {int? ignoreIndex}) {
    final error = _config.validatePromptSchemeName(
      name,
      ignoreIndex: ignoreIndex,
    );
    if (error == null) return;
    throw AgentControlException(
      'invalid_argument',
      error == PromptSchemeNameError.empty
          ? 'The scheme name must not be empty.'
          : "A prompt scheme named '${name.trim()}' already exists.",
    );
  }

  Future<AgentToolResult> _commitSchemeChange() async {
    await _store.saveConfig(_config.toJson());
    _config.notifyExternalChange();
    _onConfigReplaced?.call();
    return AgentToolResult({'updated': true, ..._schemeList()});
  }

  Map<String, dynamic> _schemeList() {
    final current = _config.currentPromptSchemeIndex;
    return {
      'prompt_mode': _config.promptMode.name,
      'current_index': current,
      'schemes': [
        for (final (index, scheme) in _config.promptSchemes.indexed)
          {
            'index': index,
            'name': scheme.name,
            'current': index == current,
            'pointer': index == current ? '' : '/prompt_schemes/$index',
            'model': scheme.profile.paramConfig.model,
            'character_count': scheme.profile.characterConfigList.length,
          },
      ],
    };
  }

  Future<AgentToolResult> _listPromptSchemes(Map<String, dynamic> _) async =>
      AgentToolResult(_schemeList());

  Future<AgentToolResult> _switchPromptScheme(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    _config.selectPromptScheme(_schemeIndex(args));
    return _commitSchemeChange();
  }

  Future<AgentToolResult> _createPromptScheme(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final name = args['name'] == null
        ? _config.nextPromptSchemeName()
        : _string(args, 'name');
    _requireSchemeName(name);
    _config.createPromptSchemeFromCurrent(
      name,
      activate: args['activate'] != false,
    );
    return _commitSchemeChange();
  }

  Future<AgentToolResult> _renamePromptScheme(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final index = _schemeIndex(args);
    final newName = _string(args, 'new_name');
    _requireSchemeName(newName, ignoreIndex: index);
    _config.renamePromptScheme(index, newName);
    return _commitSchemeChange();
  }

  Future<AgentToolResult> _movePromptScheme(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final from = _schemeIndex(args);
    final to = _optionalInt(
      args,
      'to',
      max: _config.promptSchemes.length - 1,
    );
    if (to == null) {
      throw const AgentControlException(
        'invalid_argument',
        'to must be the target zero-based index.',
      );
    }
    _config.movePromptScheme(from, to);
    return _commitSchemeChange();
  }

  Future<AgentToolResult> _deletePromptScheme(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final index = _schemeIndex(args);
    if (_config.promptSchemes.length == 1) {
      throw const AgentControlException(
        'last_scheme',
        'The last prompt scheme cannot be deleted.',
        status: 409,
      );
    }
    _config.deletePromptScheme(index);
    return _commitSchemeChange();
  }

  Map<String, dynamic> _currentConfigInfo() {
    final uuid = _store.currentUuid;
    return {
      'uuid': uuid,
      'title': _store.configIndex[uuid]?.title,
    };
  }

  // ---------------------------------------------------------------------------
  // Results

  int _resultId(Object identity) => _resultIds[identity] ??= _nextResultId++;

  Map<String, dynamic> _resultJson(AgentResultView view) {
    return {
      'id': _resultId(view.identity),
      'status': view.status,
      'title': view.title,
      if (view.info.isNotEmpty) 'info': view.info,
      if (view.message != null) 'message': view.message,
      'has_image': view.imageBytes != null && view.imageBytes!.isNotEmpty,
      if (view.currentFilePath != null) 'file_path': view.currentFilePath,
      if (view.savedFilePaths.isNotEmpty)
        'saved_file_paths': view.savedFilePaths,
      if (view.storageStatus != null) 'storage_status': view.storageStatus,
      if (view.storageError != null) 'storage_error': view.storageError,
      if (view.anlasCost != null) 'anlas_cost': view.anlasCost,
      if (view.anlasRemaining != null) 'anlas_remaining': view.anlasRemaining,
      if (view.details.isNotEmpty) 'details': _jsonSafe(view.details),
    };
  }

  static Object? _jsonSafe(Object? value) {
    if (value == null || value is bool || value is num) return value;
    if (value is String) {
      return value.length > 4000
          ? '${value.substring(0, 200)}… (${value.length} characters omitted)'
          : value;
    }
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafe(item)),
      );
    }
    if (value is Iterable) return value.map(_jsonSafe).toList();
    if (value is Uint8List) return '<${value.length} bytes>';
    return value.toString();
  }

  List<AgentResultView> _runResults() {
    final baseline = _runBaseline;
    final all = _port.results;
    if (baseline == null) return const [];
    return all.where((view) => !baseline.contains(view.identity)).toList();
  }

  AgentResultView _findResult(Map<String, dynamic> args) {
    final id = _optionalInt(args, 'id', min: 1);
    final results = _port.results;
    if (results.isEmpty) {
      throw const AgentControlException(
        'not_found',
        'There are no results yet.',
        status: 404,
      );
    }
    if (id == null) {
      return results.lastWhere(
        (view) => view.imageBytes != null,
        orElse: () => results.last,
      );
    }
    for (final view in results) {
      if (_resultId(view.identity) == id) return view;
    }
    throw AgentControlException(
      'not_found',
      'Result $id is no longer on the generation page.',
      status: 404,
    );
  }

  static const _pendingStorageStatuses = <String>{
    'queued',
    'savingSessionPng',
    'encoding',
    'publishing',
    'saving',
  };

  Future<void> _waitUntilIdle(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_generatorOccupied) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(_pollInterval);
    }
    // Let the run's result cards finish saving (e.g. JPG conversion) so the
    // returned file paths are the final ones.
    final settleDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (_runResults().any((view) =>
        view.status == 'running' ||
        _pendingStorageStatuses.contains(view.storageStatus) ||
        (view.imageBytes != null &&
            view.currentFilePath == null &&
            view.storageError == null))) {
      if (DateTime.now().isAfter(settleDeadline) ||
          DateTime.now().isAfter(deadline)) {
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  Map<String, dynamic> _runSummary({bool timedOut = false}) {
    final results = _runResults();
    return {
      'generating': _port.isActive,
      if (timedOut) 'timed_out': true,
      'completed_count': _port.completedCount,
      'results': results.map(_resultJson).toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // Prompt tree

  List<Map<String, dynamic>> _promptRoots(Map<String, dynamic> config) {
    final roots = <Map<String, dynamic>>[];
    void add(String pointer, String label) {
      try {
        final node = getAtJsonPointer(config, pointer);
        if (node is Map) roots.add({'pointer': pointer, 'label': label});
      } on JsonEditException {
        // Absent optional roots are simply not listed.
      }
    }

    for (final (prefix, profile) in [
      ('', 'random'),
      ('/fixed_profile', 'fixed'),
    ]) {
      add('$prefix/prompt_config', '$profile: prompt');
      add('$prefix/negative_prompt_config', '$profile: negative prompt');
      dynamic characters;
      try {
        characters = getAtJsonPointer(config, '$prefix/character_config');
      } on JsonEditException {
        characters = null;
      }
      if (characters is List) {
        for (var i = 0; i < characters.length; i++) {
          add('$prefix/character_config/$i/positivePromptConfig',
              '$profile: character ${i + 1} prompt');
          add('$prefix/character_config/$i/negativePromptConfig',
              '$profile: character ${i + 1} negative prompt');
        }
      }
    }
    return roots;
  }

  List<Map<String, dynamic>> _flattenPromptTree(
    Map<String, dynamic> config,
    String rootPointer, {
    bool includeStrings = true,
  }) {
    final nodes = <Map<String, dynamic>>[];
    void visit(dynamic node, List<Object> segments, List<String> names) {
      if (node is! Map) return;
      final comment = (node['comment'] ?? '').toString();
      final path = [
        ...names,
        if (names.isNotEmpty || comment.isNotEmpty) comment
      ];
      final children = node['prompts'];
      final strs = node['strs'];
      nodes.add({
        'pointer': '$rootPointer${encodeJsonPointer(segments)}',
        'path': path.join('/'),
        'comment': comment,
        'type': node['type'],
        'selectionMethod': node['selectionMethod'],
        'enabled': node['enabled'],
        'prob': node['prob'],
        'num': node['num'],
        if (node['type'] == 'str' && strs is List) ...{
          'string_count': strs.length,
          if (includeStrings) 'strs': strs,
        },
        if (node['type'] == 'config' && children is List)
          'child_count': children.length,
      });
      if (node['type'] == 'config' && children is List) {
        for (var i = 0; i < children.length; i++) {
          visit(children[i], [...segments, 'prompts', i], path);
        }
      }
    }

    visit(getAtJsonPointer(config, rootPointer), [], []);
    return nodes;
  }

  String _resolvePromptNode(Map<String, dynamic> config, String node) {
    if (node.trim().startsWith('/')) {
      final value = getAtJsonPointer(config, node);
      if (value is! Map || !value.containsKey('strs')) {
        throw AgentControlException(
          'invalid_argument',
          "'$node' does not point to a prompt node.",
        );
      }
      return node.trim();
    }
    final wanted = node.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    final matches = <String>[];
    for (final root in _promptRoots(config)) {
      for (final entry in _flattenPromptTree(
        config,
        root['pointer'] as String,
        includeStrings: false,
      )) {
        final path = entry['path'] as String;
        if (path == wanted || path.endsWith('/$wanted')) {
          matches.add(entry['pointer'] as String);
        }
      }
    }
    if (matches.isEmpty) {
      throw AgentControlException(
        'not_found',
        "No prompt node is named '$node'. Use get_prompt_tree to list paths.",
        status: 404,
      );
    }
    if (matches.length > 1) {
      throw AgentControlException(
        'ambiguous',
        "'$node' matches several nodes; pass one of these pointers instead: "
            '${matches.join(', ')}',
      );
    }
    return matches.single;
  }

  // ---------------------------------------------------------------------------
  // Tool handlers

  Future<AgentToolResult> _getStatus(Map<String, dynamic> _) async {
    final config = _config;
    int? combinations;
    try {
      combinations = config.totalCombinationTaskCount;
    } catch (_) {
      combinations = null;
    }
    final results = _port.results;
    return AgentToolResult({
      'generating': _port.isActive,
      'stopping': _port.isStopping,
      'busy': _port.isBusy,
      'completed_count': _port.completedCount,
      'generation_count': config.generationCount,
      'lock_to_all_combinations': config.lockToAllCombinations,
      if (combinations != null) 'total_combinations': combinations,
      'prompt_mode': config.promptMode.name,
      'prompt_scheme': _currentSchemeInfo(),
      'active_profile_pointer':
          config.promptMode == PromptMode.fixed ? '/fixed_profile' : '',
      'model': config.paramConfig.model,
      'current_config': _currentConfigInfo(),
      'has_api_token': config.settings.effectiveApiTokens.isNotEmpty ||
          config.settings.apiKey.isNotEmpty,
      'references': {
        'i2i': {
          'enabled': config.i2iEnabled,
          'has_image': config.i2iConfig.hasImage,
        },
        'vibe': {
          'enabled': config.vibeEnabled,
          'count':
              config.vibeConfigListV4.length + config.vibeConfigList.length,
        },
        'precise_reference': {
          'enabled': config.preciseReferenceEnabled,
          'count': config.preciseReferenceConfigList.length,
        },
      },
      'result_count': results.length,
      if (results.isNotEmpty)
        'latest_result_id': _resultId(results.last.identity),
    });
  }

  Future<AgentToolResult> _getConfig(Map<String, dynamic> args) async {
    final config = _shareableConfig();
    final pointer = args['pointer'];
    if (pointer is String && pointer.trim().isNotEmpty) {
      try {
        return AgentToolResult(getAtJsonPointer(config, pointer));
      } on JsonEditException catch (error) {
        throw AgentControlException('not_found', error.message, status: 404);
      }
    }
    return AgentToolResult(config);
  }

  Future<AgentToolResult> _updateConfig(Map<String, dynamic> args) async {
    _requireIdle();
    final patch = args['patch'];
    final operations = args['operations'];
    if (patch == null && operations == null) {
      throw const AgentControlException(
        'invalid_argument',
        'Pass "patch" (JSON Merge Patch) and/or "operations".',
      );
    }
    final before = _shareableConfig();
    var edited = _shareableConfig();
    try {
      if (patch != null) {
        edited = Map<String, dynamic>.from(
          applyJsonMergePatch(edited, _object(patch, 'patch')) as Map,
        );
      }
      if (operations != null) {
        if (operations is! List) {
          throw const AgentControlException(
            'invalid_argument',
            'operations must be a list.',
          );
        }
        applyJsonOperations(edited, operations);
      }
    } on JsonEditException catch (error) {
      throw AgentControlException('invalid_edit', error.message);
    }
    _requireSchemesUntouched(before, edited);
    await _applyCandidate(_candidateFrom(edited));
    return AgentToolResult({
      'updated': true,
      'current_config': _currentConfigInfo(),
    });
  }

  Future<AgentToolResult> _getPromptTree(Map<String, dynamic> args) async {
    final config = _shareableConfig();
    final root = args['root'];
    final includeStrings = args['include_strings'] != false;
    final roots = root is String && root.trim().isNotEmpty
        ? [
            {'pointer': root.trim(), 'label': root.trim()}
          ]
        : _promptRoots(config);
    try {
      return AgentToolResult({
        'prompt_mode': _config.promptMode.name,
        'prompt_scheme': _currentSchemeInfo(),
        'roots': [
          for (final entry in roots)
            {
              ...entry,
              'nodes': _flattenPromptTree(
                config,
                entry['pointer'] as String,
                includeStrings: includeStrings,
              ),
            },
        ],
      });
    } on JsonEditException catch (error) {
      throw AgentControlException('not_found', error.message, status: 404);
    }
  }

  static const _promptNodeFields = <String>{
    'strs',
    'enabled',
    'selectionMethod',
    'shuffled',
    'prob',
    'num',
    'randomBracketsUpper',
    'randomBracketsLower',
    'comment',
    'filter',
    'useAsFileNamePrefix',
    'type',
    'prompts',
  };

  Future<AgentToolResult> _setPromptNode(Map<String, dynamic> args) async {
    _requireIdle();
    final changes = _object(args['changes'], 'changes');
    final unknown =
        changes.keys.where((key) => !_promptNodeFields.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw AgentControlException(
        'invalid_argument',
        'Unknown prompt node fields: ${unknown.join(', ')}. '
            'Allowed: ${_promptNodeFields.join(', ')}.',
      );
    }
    final strs = changes['strs'];
    if (strs is String) changes['strs'] = strs.split('\n');
    final edited = _shareableConfig();
    final pointer = _resolvePromptNode(edited, _string(args, 'node'));
    final node = getAtJsonPointer(edited, pointer) as Map;
    node.addAll(deepCopyJson(changes) as Map);
    await _applyCandidate(_candidateFrom(edited));
    final updated = getAtJsonPointer(_shareableConfig(), pointer) as Map;
    return AgentToolResult({
      'updated': true,
      'pointer': pointer,
      'node': {
        for (final key in _promptNodeFields)
          if (key != 'prompts') key: updated[key],
      },
    });
  }

  Future<AgentToolResult> _listConfigs(Map<String, dynamic> _) async {
    final entries = _store.configIndex.entries.toList()
      ..sort((a, b) => b.value.lastModified.compareTo(a.value.lastModified));
    return AgentToolResult({
      'current_uuid': _store.currentUuid,
      'configs': [
        for (final entry in entries)
          {
            'uuid': entry.key,
            'title': entry.value.title,
            'last_modified': entry.value.lastModified.toIso8601String(),
            'current': entry.key == _store.currentUuid,
          },
      ],
    });
  }

  String _resolveConfigUuid(Map<String, dynamic> args) {
    final uuid = args['uuid'];
    if (uuid is String && uuid.isNotEmpty) {
      if (!_store.configIndex.containsKey(uuid)) {
        throw AgentControlException(
          'not_found',
          'No saved configuration has uuid $uuid.',
          status: 404,
        );
      }
      return uuid;
    }
    final title = args['title'];
    if (title is String && title.isNotEmpty) {
      final matches = _store.configIndex.entries
          .where((entry) => entry.value.title == title)
          .map((entry) => entry.key)
          .toList();
      if (matches.length == 1) return matches.single;
      throw AgentControlException(
        matches.isEmpty ? 'not_found' : 'ambiguous',
        matches.isEmpty
            ? "No saved configuration is titled '$title'."
            : "Several configurations are titled '$title'; pass a uuid.",
        status: matches.isEmpty ? 404 : 400,
      );
    }
    throw const AgentControlException(
      'invalid_argument',
      'Pass "uuid" or "title".',
    );
  }

  Future<AgentToolResult> _switchConfig(Map<String, dynamic> args) async {
    _requireIdle();
    final uuid = _resolveConfigUuid(args);
    if (uuid == _store.currentUuid) {
      return AgentToolResult(
          {'switched': false, 'current_config': _currentConfigInfo()});
    }
    final selected = await _store.selectConfig(
      uuid,
      currentConfig: _config.toJson(),
    );
    _config.loadJson(selected);
    _config.notifyExternalChange();
    _onConfigReplaced?.call();
    return AgentToolResult({
      'switched': true,
      'current_config': _currentConfigInfo(),
    });
  }

  Future<AgentToolResult> _saveConfigAs(Map<String, dynamic> args) async {
    final title = _string(args, 'title');
    final makeCurrent = args['switch'] == true;
    if (makeCurrent) _requireIdle();
    await _store.saveConfig(_config.toJson());
    final uuid = await _store.saveNewConfig(
      _config.toJson(),
      title: title,
      makeCurrent: makeCurrent,
    );
    return AgentToolResult({
      'uuid': uuid,
      'title': title,
      'current_config': _currentConfigInfo(),
    });
  }

  Future<AgentToolResult> _renameConfig(Map<String, dynamic> args) async {
    final uuid = _resolveConfigUuid(args);
    final newTitle = _string(args, 'new_title');
    await _store.renameConfigByUuid(uuid, newTitle);
    return AgentToolResult({'uuid': uuid, 'title': newTitle});
  }

  Future<AgentToolResult> _deleteConfig(Map<String, dynamic> args) async {
    final uuid = _resolveConfigUuid(args);
    if (uuid == _store.currentUuid) {
      throw const AgentControlException(
        'invalid_argument',
        'The current configuration cannot be deleted; switch first.',
      );
    }
    await _store.deleteConfigByUuid(uuid);
    return AgentToolResult({'deleted': uuid});
  }

  Future<AgentToolResult> _exportConfig(Map<String, dynamic> args) async {
    if (args['uuid'] == null && args['title'] == null) {
      return AgentToolResult(_shareableConfig());
    }
    final uuid = _resolveConfigUuid(args);
    final saved = uuid == _store.currentUuid
        ? _config.toJson()
        : _store.loadConfigByUuid(uuid);
    if (saved == null) {
      throw const AgentControlException(
        'not_found',
        'The saved configuration could not be read.',
        status: 404,
      );
    }
    return AgentToolResult(_shareableConfig(saved));
  }

  Future<AgentToolResult> _importConfig(Map<String, dynamic> args) async {
    final config = _object(args['config'], 'config');
    final mode = (args['mode'] ?? 'replace_current').toString();
    switch (mode) {
      case 'replace_current':
        _requireIdle();
        await _applyCandidate(_candidateFrom(config));
        return AgentToolResult({
          'imported': true,
          'mode': mode,
          'current_config': _currentConfigInfo(),
        });
      case 'save_as_new':
        final candidate = _candidateFrom(config);
        final title = (args['title'] as String?)?.trim();
        final uuid = await _store.saveImportedConfig(
          candidate,
          title: title == null || title.isEmpty ? 'Imported by agent' : title,
        );
        return AgentToolResult({'imported': true, 'mode': mode, 'uuid': uuid});
      default:
        throw AgentControlException(
          'invalid_argument',
          "mode must be 'replace_current' or 'save_as_new', not '$mode'.",
        );
    }
  }

  Future<Uint8List> _readImageFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw AgentControlException(
        'not_found',
        'File does not exist: $path',
        status: 404,
      );
    }
    return file.readAsBytes();
  }

  Future<AgentToolResult> _addReferenceImage(Map<String, dynamic> args) async {
    _requireIdle();
    final kind = _string(args, 'kind');
    final path = _string(args, 'path');
    final bytes = await _readImageFile(path);
    final fileName = path.split(Platform.pathSeparator).last;
    final config = _config;
    switch (kind) {
      case 'vibe':
        config.addVibeImage(
          bytes,
          fileName,
          referenceStrength: _optionalDouble(args, 'strength') ?? 0.6,
          informationExtracted:
              _optionalDouble(args, 'information_extracted') ?? 0.7,
        );
      case 'precise_reference':
        final typeName = args['reference_type']?.toString();
        final type = typeName == null
            ? PreciseReferenceType.characterAndStyle
            : PreciseReferenceType.values.firstWhere(
                (value) => value.name == typeName,
                orElse: () => throw AgentControlException(
                  'invalid_argument',
                  'reference_type must be one of '
                      '${PreciseReferenceType.values.map((v) => v.name).join(', ')}.',
                ),
              );
        await config.addPreciseReferenceImage(bytes, fileName);
        final added = config.preciseReferenceConfigList.last..type = type;
        final strength = _optionalDouble(args, 'strength');
        final fidelity = _optionalDouble(args, 'fidelity');
        if (strength != null) added.strength = strength.clamp(0.0, 1.0);
        if (fidelity != null) added.fidelity = fidelity.clamp(0.0, 1.0);
      case 'i2i_base':
        final (width, height) = await compute(_imageSize, bytes);
        if (width <= 0 || height <= 0) {
          throw const AgentControlException(
            'invalid_image',
            'Image dimensions are unavailable.',
          );
        }
        final preview = width <= 512 && height <= 512
            ? bytes
            : await compute(_createI2iPreview, bytes);
        if (config.batchToolKind != null) config.deactivateBatchTool();
        final replacing = config.i2iConfig.hasImage;
        config.i2iConfig.setPreparedImage(
          bytes,
          width: width,
          height: height,
          previewBytes: preview,
        );
        config.noteI2iImported(replacing: replacing, explicitUse: true);
        final strength = _optionalDouble(args, 'strength');
        final noise = _optionalDouble(args, 'noise');
        if (strength != null) config.i2iConfig.setStrength(strength);
        if (noise != null) config.i2iConfig.setNoise(noise);
      default:
        throw const AgentControlException(
          'invalid_argument',
          "kind must be 'vibe', 'precise_reference' or 'i2i_base'.",
        );
    }
    config.notifyExternalChange();
    return AgentToolResult(_referenceSummary());
  }

  Map<String, dynamic> _referenceSummary() {
    final config = _config;
    return {
      'i2i': {
        'enabled': config.i2iEnabled,
        'has_image': config.i2iConfig.hasImage,
        'strength': config.i2iConfig.strength,
        'noise': config.i2iConfig.noise,
      },
      'vibe': {
        'enabled': config.vibeEnabled,
        'items': [
          for (final vibe in config.vibeConfigListV4)
            {
              'file_name': vibe.fileName,
              'strength': vibe.referenceStrength,
              'information_extracted': vibe.informationExtracted,
            },
          for (final vibe in config.vibeConfigList)
            {
              'file_name': vibe.fileName,
              'strength': vibe.referenceStrength,
              'information_extracted': vibe.infoExtracted,
              'legacy': true,
            },
        ],
      },
      'precise_reference': {
        'enabled': config.preciseReferenceEnabled,
        'items': [
          for (final reference in config.preciseReferenceConfigList)
            {
              'file_name': reference.fileName,
              'type': reference.type.name,
              'strength': reference.strength,
              'fidelity': reference.fidelity,
              'enabled': reference.enabled,
            },
        ],
      },
    };
  }

  Future<AgentToolResult> _clearReferenceImages(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final kind = _string(args, 'kind');
    final config = _config;
    switch (kind) {
      case 'vibe':
        config.vibeConfigListV4.clear();
        config.vibeConfigList.clear();
        config.clearVibeResourceState();
      case 'precise_reference':
        config.preciseReferenceConfigList.clear();
        config.clearPreciseReferenceResourceState();
      case 'i2i_base':
        config.i2iConfig.removeImage();
        config.clearI2iResourceState();
      default:
        throw const AgentControlException(
          'invalid_argument',
          "kind must be 'vibe', 'precise_reference' or 'i2i_base'.",
        );
    }
    config.notifyExternalChange();
    return AgentToolResult(_referenceSummary());
  }

  Future<AgentToolResult> _setReferenceFeature(
    Map<String, dynamic> args,
  ) async {
    _requireIdle();
    final feature = _string(args, 'feature');
    final enabled = args['enabled'];
    if (enabled is! bool) {
      throw const AgentControlException(
        'invalid_argument',
        'enabled must be true or false.',
      );
    }
    final config = _config;
    switch (feature) {
      case 'i2i':
        config.setI2iEnabled(enabled);
      case 'vibe':
        config.setVibeEnabled(enabled);
      case 'precise_reference':
        config.setPreciseReferenceEnabled(enabled);
      default:
        throw const AgentControlException(
          'invalid_argument',
          "feature must be 'i2i', 'vibe' or 'precise_reference'.",
        );
    }
    config.notifyExternalChange();
    return AgentToolResult(_referenceSummary());
  }

  Future<AgentToolResult> _startGeneration(Map<String, dynamic> args) async {
    if (_generatorOccupied) {
      throw const AgentControlException(
        'generation_in_progress',
        'Generation is already running.',
        status: 409,
      );
    }
    final config = _config;
    if (config.settings.effectiveApiTokens.isEmpty &&
        config.settings.apiKey.isEmpty &&
        !config.settings.debugApiEnabled) {
      throw const AgentControlException(
        'no_api_token',
        'No NovelAI token is configured. The user must add one in the app.',
        status: 412,
      );
    }
    final count = _optionalInt(args, 'count', min: 0);
    final timeout = Duration(
      seconds: _optionalInt(args, 'timeout_sec', min: 1, max: 3600) ?? 300,
    );
    // Not queued with the other edits: a waiting run must not block
    // stop_generation. [_starting] closes the gap until the port is active.
    _starting = true;
    try {
      // Let earlier accepted edits finish before the run reads the config.
      await _mutationTail;
      if (count != null && count != config.generationCount) {
        config.generationCount = count;
        await _store.saveConfig(config.toJson());
        config.notifyExternalChange();
      }
      _runBaseline = _port.results.map((view) => view.identity).toSet();
      _port.start();
    } finally {
      _starting = false;
    }
    if (!_port.isActive) {
      final added = _runResults();
      final reason = added.isEmpty
          ? 'The generator did not start. The prompt combination cycle may be '
              'too large for "lock to all combinations", or no account is '
              'currently eligible.'
          : '${added.last.title}\n${added.last.info}'.trim();
      throw AgentControlException('start_failed', reason, status: 409);
    }
    _onActivity?.call('start_generation');
    final effectiveCount = config.settings.generationCount;
    if (args['wait'] == true) {
      await _waitUntilIdle(timeout);
      return AgentToolResult({
        'started': true,
        'count': effectiveCount,
        ..._runSummary(timedOut: _generatorOccupied),
      });
    }
    return AgentToolResult({
      'started': true,
      'count': effectiveCount,
      'unlimited': effectiveCount == 0,
    });
  }

  Future<AgentToolResult> _stopGeneration(Map<String, dynamic> args) async {
    final wasActive = _port.isActive;
    if (wasActive) {
      _port.stop();
      _onActivity?.call('stop_generation');
    }
    if (args['wait'] != false && wasActive) {
      await _waitUntilIdle(const Duration(seconds: 120));
    }
    return AgentToolResult({
      'was_generating': wasActive,
      ..._runSummary(),
    });
  }

  Future<AgentToolResult> _waitForGeneration(Map<String, dynamic> args) async {
    final timeout = Duration(
      seconds: _optionalInt(args, 'timeout_sec', min: 1, max: 3600) ?? 300,
    );
    await _waitUntilIdle(timeout);
    return AgentToolResult(_runSummary(timedOut: _generatorOccupied));
  }

  Future<AgentToolResult> _listResults(Map<String, dynamic> args) async {
    final limit = _optionalInt(args, 'limit', min: 1, max: 200) ?? 20;
    final sinceId = _optionalInt(args, 'since_id', min: 0) ?? 0;
    final views = _port.results
        .where((view) => _resultId(view.identity) > sinceId)
        .toList();
    final selected =
        views.length > limit ? views.sublist(views.length - limit) : views;
    return AgentToolResult({
      'results': selected.map(_resultJson).toList(),
      'total_on_page': _port.results.length,
    });
  }

  Future<AgentToolResult> _getResultImage(Map<String, dynamic> args) async {
    final view = _findResult(args);
    final bytes = view.imageBytes;
    if (bytes == null || bytes.isEmpty) {
      throw AgentControlException(
        'no_image',
        'Result ${_resultId(view.identity)} has no image.',
        status: 404,
      );
    }
    final size = (args['size'] ?? 'preview').toString();
    final AgentImage image;
    if (size == 'full') {
      image = AgentImage(bytes, sniffImageMimeType(bytes));
    } else {
      final edge = _optionalInt(args, 'max_edge', min: 64, max: 2048) ?? 768;
      image = AgentImage(
        await compute(_createJpegPreview, (bytes, edge)),
        'image/jpeg',
      );
    }
    return AgentToolResult(
      _resultJson(view)..remove('details'),
      images: [image],
    );
  }

  /// Raw image bytes for the REST image endpoint.
  Future<AgentImage> resultImageBytes(int id, {bool full = true}) async {
    final result = await _getResultImage({
      'id': id,
      'size': full ? 'full' : 'preview',
    });
    return result.images.single;
  }

  // ---------------------------------------------------------------------------
  // Tool catalogue

  List<AgentTool> _buildTools() {
    const empty = {'type': 'object', 'properties': {}};
    Map<String, dynamic> schema(
      Map<String, dynamic> properties, {
      List<String> required = const [],
    }) =>
        {
          'type': 'object',
          'properties': properties,
          if (required.isNotEmpty) 'required': required,
        };
    const configSelector = {
      'uuid': {'type': 'string', 'description': 'Saved configuration uuid.'},
      'title': {
        'type': 'string',
        'description': 'Saved configuration title (must be unique).',
      },
    };
    const schemeSelector = {
      'index': {'type': 'integer', 'description': 'Zero-based scheme index.'},
      'name': {'type': 'string', 'description': 'Unique scheme name.'},
    };
    const referenceKind = {
      'type': 'string',
      'enum': ['vibe', 'precise_reference', 'i2i_base'],
    };
    return [
      AgentTool(
        name: 'get_status',
        description: 'Generation state, progress, current configuration, '
            'model, prompt mode and reference-image state.',
        inputSchema: empty,
        handler: _getStatus,
      ),
      AgentTool(
        name: 'get_config',
        description: 'Return the whole current configuration as JSON (the '
            'same document the app exports, without credentials), or the '
            'part at "pointer" (RFC 6901, e.g. /param_config/steps). The '
            'current random prompt scheme lives at the top level; other '
            'schemes under /prompt_schemes/<index>; the fixed profile under '
            '/fixed_profile. prompt_mode selects random or fixed.',
        inputSchema: schema({
          'pointer': {'type': 'string'},
        }),
        handler: _getConfig,
      ),
      AgentTool(
        name: 'update_config',
        description: 'Edit any part of the current configuration, exactly '
            'what a user can change in the app (prompts, characters, model, '
            'sizes, steps, scale, sampler, seed, counts, prompt_mode, '
            'settings such as output_folder or image_save_format). Pass a '
            'JSON Merge Patch in "patch" and/or pointer edits in '
            '"operations" ([{"op":"set","path":"/param_config/steps",'
            '"value":28}], op is set or remove; "-" appends to a list). '
            'Changes are validated, saved and shown in the app immediately. '
            'Credentials, API base URL and proxy cannot be changed. '
            'The scheme list and selection are changed with the '
            '*_prompt_scheme tools. Refused while generating.',
        inputSchema: schema({
          'patch': {'type': 'object'},
          'operations': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'op': {
                  'type': 'string',
                  'enum': ['set', 'remove'],
                },
                'path': {'type': 'string'},
                'value': {},
              },
              'required': ['path'],
            },
          },
        }),
        mutates: true,
        handler: _updateConfig,
      ),
      AgentTool(
        name: 'get_prompt_tree',
        description: 'List the cascading prompt nodes of every prompt root '
            '(current random prompt scheme and fixed profile, negative '
            'prompts, characters) with their JSON pointer, comment path '
            '(e.g. "测试用/画师"), type, selectionMethod, enabled and strings. '
            'Use "root" to limit the listing to one pointer (for another '
            'scheme, /prompt_schemes/<index>/prompt_config) and '
            'include_strings=false to omit strings.',
        inputSchema: schema({
          'root': {'type': 'string'},
          'include_strings': {'type': 'boolean'},
        }),
        handler: _getPromptTree,
      ),
      AgentTool(
        name: 'set_prompt_node',
        description: 'Change one prompt node, addressed by its comment path '
            '(as listed by get_prompt_tree, e.g. "测试用/画师"; a unique '
            'suffix is enough) or by its JSON pointer. "changes" may set '
            'strs (list, or one string split on newlines), enabled, '
            'selectionMethod (single, all, multiple_num, multiple_prob, '
            'single_sequential), num, prob, shuffled, comment, filter, '
            'randomBracketsLower/Upper, useAsFileNamePrefix, type, prompts. '
            'Refused while generating.',
        inputSchema: schema({
          'node': {'type': 'string'},
          'changes': {'type': 'object'},
        }, required: [
          'node',
          'changes'
        ]),
        mutates: true,
        handler: _setPromptNode,
      ),
      AgentTool(
        name: 'list_prompt_schemes',
        description: 'List the random prompt schemes of the current '
            'configuration. A scheme owns its prompts, characters, negative '
            'prompt and generation parameters; saved configs, Vibe and '
            'reference images are shared. Each entry gives the JSON pointer '
            'of its content ("" is the top level, for the current scheme).',
        inputSchema: empty,
        handler: _listPromptSchemes,
      ),
      AgentTool(
        name: 'switch_prompt_scheme',
        description: 'Make a prompt scheme current. Pass its "index" or '
            '"name". Refused while generating.',
        inputSchema: schema(schemeSelector),
        handler: _switchPromptScheme,
        mutates: true,
      ),
      AgentTool(
        name: 'create_prompt_scheme',
        description: 'Append a copy of the current prompt scheme to the list '
            'and make the copy current (activate=false keeps the current '
            'scheme). "name" is optional and must be unique. Refused while '
            'generating.',
        inputSchema: schema({
          'name': {'type': 'string'},
          'activate': {'type': 'boolean'},
        }),
        handler: _createPromptScheme,
        mutates: true,
      ),
      AgentTool(
        name: 'rename_prompt_scheme',
        description: 'Rename the scheme chosen by "index" or "name" to '
            '"new_name", which must be unique. Refused while generating.',
        inputSchema: schema({
          ...schemeSelector,
          'new_name': {'type': 'string'},
        }, required: const [
          'new_name'
        ]),
        handler: _renamePromptScheme,
        mutates: true,
      ),
      AgentTool(
        name: 'move_prompt_scheme',
        description: 'Move the scheme chosen by "index" or "name" to the '
            'zero-based position "to". The current scheme stays current. '
            'Refused while generating.',
        inputSchema: schema({
          ...schemeSelector,
          'to': {'type': 'integer'},
        }, required: const [
          'to'
        ]),
        handler: _movePromptScheme,
        mutates: true,
      ),
      AgentTool(
        name: 'delete_prompt_scheme',
        description: 'Delete the scheme chosen by "index" or "name". The '
            'last scheme cannot be deleted. Refused while generating.',
        inputSchema: schema(schemeSelector),
        handler: _deletePromptScheme,
        mutates: true,
      ),
      AgentTool(
        name: 'list_configs',
        description: 'List saved configurations (uuid, title, last modified, '
            'which one is current).',
        inputSchema: empty,
        handler: _listConfigs,
      ),
      AgentTool(
        name: 'switch_config',
        description: 'Make a saved configuration current (by uuid or unique '
            'title). The outgoing one is saved first. Refused while '
            'generating.',
        inputSchema: schema(configSelector),
        mutates: true,
        handler: _switchConfig,
      ),
      AgentTool(
        name: 'save_config_as',
        description: 'Save a copy of the current configuration under a new '
            'title; with switch=true the copy becomes current.',
        inputSchema: schema({
          'title': {'type': 'string'},
          'switch': {'type': 'boolean'},
        }, required: [
          'title'
        ]),
        mutates: true,
        handler: _saveConfigAs,
      ),
      AgentTool(
        name: 'rename_config',
        description: 'Rename a saved configuration (select by uuid or title).',
        inputSchema: schema({
          ...configSelector,
          'new_title': {'type': 'string'},
        }, required: [
          'new_title'
        ]),
        mutates: true,
        handler: _renameConfig,
      ),
      AgentTool(
        name: 'delete_config',
        description: 'Delete a saved configuration that is not current.',
        inputSchema: schema(configSelector),
        mutates: true,
        handler: _deleteConfig,
      ),
      AgentTool(
        name: 'export_config',
        description: 'Return a saved configuration (or the current one when '
            'no uuid/title is given) as importable JSON without credentials.',
        inputSchema: schema(configSelector),
        handler: _exportConfig,
      ),
      AgentTool(
        name: 'import_config',
        description: 'Import a whole configuration JSON (as produced by '
            'export_config or the app). mode=replace_current (default) loads '
            'it into the current configuration; mode=save_as_new stores it '
            'as a new saved configuration with "title".',
        inputSchema: schema({
          'config': {'type': 'object'},
          'mode': {
            'type': 'string',
            'enum': ['replace_current', 'save_as_new'],
          },
          'title': {'type': 'string'},
        }, required: [
          'config'
        ]),
        mutates: true,
        handler: _importConfig,
      ),
      AgentTool(
        name: 'list_reference_images',
        description: 'Show the image-to-image base image, Vibe Transfer and '
            'Precise Reference images currently loaded (these are not saved '
            'in configurations).',
        inputSchema: empty,
        handler: (_) async => AgentToolResult(_referenceSummary()),
      ),
      AgentTool(
        name: 'add_reference_image',
        description: 'Load a local image file as a reference. kind=vibe '
            '(strength, information_extracted), precise_reference '
            '(reference_type: character, style, characterAndStyle; strength, '
            'fidelity) or i2i_base (image-to-image base image; strength, '
            'noise). The feature is enabled like an import in the app.',
        inputSchema: schema({
          'kind': referenceKind,
          'path': {'type': 'string', 'description': 'Absolute file path.'},
          'strength': {'type': 'number'},
          'information_extracted': {'type': 'number'},
          'fidelity': {'type': 'number'},
          'noise': {'type': 'number'},
          'reference_type': {
            'type': 'string',
            'enum': ['character', 'style', 'characterAndStyle'],
          },
        }, required: [
          'kind',
          'path'
        ]),
        mutates: true,
        handler: _addReferenceImage,
      ),
      AgentTool(
        name: 'clear_reference_images',
        description: 'Remove every reference image of one kind.',
        inputSchema: schema({'kind': referenceKind}, required: ['kind']),
        mutates: true,
        handler: _clearReferenceImages,
      ),
      AgentTool(
        name: 'set_reference_feature',
        description: 'Turn image-to-image, Vibe Transfer or Precise '
            'Reference on or off without removing the images.',
        inputSchema: schema({
          'feature': {
            'type': 'string',
            'enum': ['i2i', 'vibe', 'precise_reference'],
          },
          'enabled': {'type': 'boolean'},
        }, required: [
          'feature',
          'enabled'
        ]),
        mutates: true,
        handler: _setReferenceFeature,
      ),
      AgentTool(
        name: 'start_generation',
        description: 'Press Generate. "count" sets how many images to make '
            '(0 = until stopped; omitted = the configured count). With '
            'wait=true the call returns when the run ends (timeout_sec, '
            'default 300) together with its results; otherwise poll '
            'get_status or call wait_for_generation. This spends the '
            "user's NovelAI Anlas exactly like the app's button.",
        inputSchema: schema({
          'count': {'type': 'integer', 'minimum': 0},
          'wait': {'type': 'boolean'},
          'timeout_sec': {'type': 'integer', 'minimum': 1},
        }),
        handler: _startGeneration,
      ),
      AgentTool(
        name: 'stop_generation',
        description: 'Stop the running generation (requests already sent '
            'still finish). Waits until stopped unless wait=false.',
        inputSchema: schema({
          'wait': {'type': 'boolean'},
        }),
        handler: _stopGeneration,
      ),
      AgentTool(
        name: 'wait_for_generation',
        description: 'Wait until the current run finishes (timeout_sec, '
            'default 300) and return the results it produced.',
        inputSchema: schema({
          'timeout_sec': {'type': 'integer', 'minimum': 1},
        }),
        handler: _waitForGeneration,
      ),
      AgentTool(
        name: 'list_results',
        description: 'List result cards on the generation page, newest '
            'last: id, status, saved file paths, prompt and parameters. '
            'Use since_id to get only newer results.',
        inputSchema: schema({
          'limit': {'type': 'integer', 'minimum': 1},
          'since_id': {'type': 'integer', 'minimum': 0},
        }),
        handler: _listResults,
      ),
      AgentTool(
        name: 'get_result_image',
        description: 'Return a result image (the latest when id is '
            'omitted). size=preview (default) is a JPEG scaled to max_edge '
            '(default 768); size=full is the original file. The saved file '
            'path is included as well.',
        inputSchema: schema({
          'id': {'type': 'integer', 'minimum': 1},
          'size': {
            'type': 'string',
            'enum': ['preview', 'full'],
          },
          'max_edge': {'type': 'integer', 'minimum': 64},
        }),
        handler: _getResultImage,
      ),
    ];
  }
}
