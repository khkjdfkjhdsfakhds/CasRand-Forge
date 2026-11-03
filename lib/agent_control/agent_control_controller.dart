import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:nai_casrand/agent_control/agent_control_server.dart';
import 'package:nai_casrand/agent_control/agent_control_service.dart';
import 'package:path_provider/path_provider.dart';

const agentControlDiscoveryFileName = 'agent-control.json';
const agentControlDefaultPort = 47823;

bool get agentControlPlatformSupported {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

/// Preferences that survive restarts; kept outside saved configurations so a
/// configuration switch or import never turns remote control on or off.
abstract class AgentControlPreferences {
  bool get enabled;
  set enabled(bool value);
  String? get token;
  set token(String? value);
}

class HiveAgentControlPreferences implements AgentControlPreferences {
  HiveAgentControlPreferences(this._box);

  final Box _box;

  @override
  bool get enabled => _box.get('agentControlEnabled') == true;

  @override
  set enabled(bool value) => _box.put('agentControlEnabled', value);

  @override
  String? get token {
    final value = _box.get('agentControlToken');
    return value is String && value.isNotEmpty ? value : null;
  }

  @override
  set token(String? value) => _box.put('agentControlToken', value);
}

class AgentActivity {
  final String action;
  final DateTime time;

  const AgentActivity(this.action, this.time);
}

/// Owns the local server's lifecycle, its access token and the discovery
/// file agents read (`agent-control.json` in Application Support).
class AgentControlController extends ChangeNotifier {
  AgentControlController({
    required AgentControlService Function(AgentControlController) service,
    required AgentControlPreferences preferences,
    required this.appVersion,
    Future<Directory> Function()? discoveryDirectory,
    this.preferredPort = agentControlDefaultPort,
  })  : _serviceFactory = service,
        _preferences = preferences,
        _discoveryDirectory =
            discoveryDirectory ?? getApplicationSupportDirectory;

  final AgentControlService Function(AgentControlController) _serviceFactory;
  final AgentControlPreferences _preferences;
  final Future<Directory> Function() _discoveryDirectory;
  final String appVersion;
  final int preferredPort;

  late final AgentControlService service = _serviceFactory(this);
  AgentControlServer? _server;
  Future<void> _transition = Future<void>.value();

  Object? lastError;
  String? discoveryFilePath;
  AgentActivity? lastActivity;

  /// Bumped after an agent replaced the configuration (theme and pages that
  /// cache settings refresh on it).
  final ValueNotifier<int> configRevision = ValueNotifier(0);
  final StreamController<AgentActivity> _activities =
      StreamController.broadcast();
  Stream<AgentActivity> get activities => _activities.stream;

  bool get enabled => _preferences.enabled;
  bool get isRunning => _server?.isRunning ?? false;
  int? get port => _server?.port;
  String? get token => _preferences.token;

  String? get baseUrl => port == null ? null : 'http://127.0.0.1:$port';
  String? get mcpUrl => baseUrl == null ? null : '$baseUrl/mcp';

  /// A ready-to-run command that registers this server with Claude Code.
  String? get claudeCodeCommand => mcpUrl == null
      ? null
      : 'claude mcp add --transport http --scope user casrand $mcpUrl '
          '--header "Authorization: Bearer $token"';

  void recordActivity(String action) {
    final activity = AgentActivity(action, DateTime.now());
    lastActivity = activity;
    _activities.add(activity);
    notifyListeners();
  }

  void notifyConfigReplaced() => configRevision.value++;

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Starts the server at launch when the user enabled it earlier.
  Future<void> restore() async {
    if (enabled && agentControlPlatformSupported) await _run(_start);
  }

  Future<void> setEnabled(bool value) async {
    _preferences.enabled = value;
    notifyListeners();
    await _run(value ? _start : _stop);
  }

  /// Invalidates the old token; connected agents must re-read the file.
  Future<void> regenerateToken() async {
    _preferences.token = generateToken();
    if (isRunning) {
      await _run(() async {
        await _stop();
        await _start();
      });
    }
    notifyListeners();
  }

  /// Closes the server and removes the discovery file before the app exits.
  Future<void> shutdown() => _run(_stop);

  Future<void> _run(Future<void> Function() action) {
    final next = _transition.then((_) => action());
    _transition = next.catchError((_) {});
    return next;
  }

  Future<void> _start() async {
    if (isRunning) return;
    lastError = null;
    var token = _preferences.token;
    if (token == null) {
      token = generateToken();
      _preferences.token = token;
    }
    final server = AgentControlServer(
      service: service,
      token: token,
      serverVersion: appVersion,
    );
    try {
      await server.start(preferredPort: preferredPort);
      _server = server;
      await _writeDiscoveryFile();
    } catch (error) {
      lastError = error;
      await server.stop();
      _server = null;
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    await server?.stop();
    await _deleteDiscoveryFile();
    notifyListeners();
  }

  Future<File> _discoveryFile() async {
    final directory = await _discoveryDirectory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return File(
      '${directory.path}${Platform.pathSeparator}$agentControlDiscoveryFileName',
    );
  }

  Future<void> _writeDiscoveryFile() async {
    final file = await _discoveryFile();
    final content = const JsonEncoder.withIndent('  ').convert({
      'app': 'CasRand Forge',
      'version': appVersion,
      'pid': pid,
      'mcp_url': mcpUrl,
      'rest_base_url': '$baseUrl/api/v1',
      'token': token,
      'authorization_header': 'Bearer $token',
      'claude_code_command': claudeCodeCommand,
    });
    await file.writeAsString(content, flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {
        // Application Support is already private to the user.
      }
    }
    discoveryFilePath = file.path;
  }

  Future<void> _deleteDiscoveryFile() async {
    try {
      final file = await _discoveryFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale file only points to a closed port.
    }
  }

  @override
  void dispose() {
    unawaited(_server?.stop());
    _activities.close();
    configRevision.dispose();
    super.dispose();
  }
}
