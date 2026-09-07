// ignore_for_file: avoid_print, prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/generation_page/widgets/generation_page_view.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:vm_service/vm_service.dart' as service;
import 'package:vm_service/vm_service_io.dart';
import 'package:nai_casrand/data/models/api_request.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/services/api_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

class FakeApi extends ApiService {
  FakeApi(this.data);
  final Uint8List data;
  int calls = 0;
  @override
  Future<ApiResponse> fetchData(ApiRequest req) async {
    calls++;
    return ApiResponse(status: '200', data: data);
  }
}

class WeakStorage implements GeneratedImageStorage {
  final refs = <WeakReference<Uint8List>>[];
  final artifacts = <WeakReference<GeneratedImageArtifact>>[];
  int previewLength = 0;
  @override
  GeneratedImageStorageSubmission submit(GeneratedImageStorageRequest request) {
    previewLength = request.pngBytes.length;
    final submission = GeneratedImageStorageSubmission.start(
        previewBytes: request.pngBytes,
        publish: () async => GeneratedImageFile(
            path: '/SYNTHETIC/${request.fileName}',
            mediaType: 'image/png',
            isPermanent: true));
    refs.add(WeakReference(submission.artifact.previewBytes));
    artifacts.add(WeakReference(submission.artifact));
    return submission;
  }
}

PayloadConfig fixture() => PayloadConfig(
    rootPromptConfig: PromptConfig(strs: ['SYNTHETIC_PROMPT'], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(),
    settings: Settings.fromJson({
      'api_key': 'TOKEN_SYNTHETIC',
      'generation_count': 250,
      'generation_interval': 0
    })
      ..debugApiEnabled = true,
    overridePrompt: '',
    useOverridePrompt: false,
    useCharacterPromptWithOverride: false);
Uint8List syntheticZip() {
  final image = img.Image(width: 256, height: 256, numChannels: 3);
  final rng = Random(4711);
  for (final pixel in image) {
    pixel.setRgb(rng.nextInt(256), rng.nextInt(256), rng.nextInt(256));
  }
  final png = img.encodePng(image);
  return Uint8List.fromList(ZipEncoder().encode(
      Archive()..addFile(ArchiveFile('image_0.png', png.length, png)))!);
}

@pragma('vm:never-inline')
WeakReference<Object> sentinel() => WeakReference(Object());
@pragma('vm:never-inline')
int alive(List<WeakReference<Uint8List>> refs, int count) =>
    refs.take(count).where((r) => r.target != null).length;
Future<void> waitBatch(CommandStatus status) async {
  final watch = Stopwatch()..start();
  while (status.isGenerationActive.value) {
    if (watch.elapsed > const Duration(seconds: 30)) {
      throw StateError('Synthetic batch timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

Future<service.VmService> openService() async {
  var info = await developer.Service.getInfo();
  if (info.serverUri == null) {
    info = await developer.Service.controlWebServer(
        enable: true, silenceOutput: true);
  }
  final uri = info.serverUri;
  if (uri == null) throw StateError('VM service unavailable');
  return vmServiceConnectUri(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString());
}

class Loader extends AssetLoader {
  final Map<String, dynamic> words;
  Loader(this.words);
  @override
  Future<Map<String, dynamic>> load(String p, Locale l) async => words;
}

@pragma('vm:never-inline')
void addSyntheticCard(
    GenerationPageViewmodel vm,
    List<WeakReference<Command<void, InfoCardContent>>> refs,
    Uint8List png,
    int index) {
  final content = InfoCardContent(
      title: 'SYNTHETIC_$index',
      info: 'SYNTHETIC_PROMPT',
      additionalInfo: const {},
      imageBytes: Uint8List.fromList(png));
  final command = Command.createAsyncNoParam(() async => content,
      initialValue: InfoCardContent.fromEmpty());
  refs.add(WeakReference(command));
  vm.addAndRunCommand(command);
}

@pragma('vm:never-inline')
int aliveCommands(
        List<WeakReference<Command<void, InfoCardContent>>> refs, int count) =>
    refs.take(count).where((r) => r.target != null).length;
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, dynamic> translations;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (c) async => c.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    translations =
        jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
  });
  test('MEM01 completed batch evicted previews release after full GC',
      () async {
    await GetIt.I.reset();
    final payload = fixture();
    final status = CommandStatus();
    GetIt.I.registerSingleton(payload);
    GetIt.I.registerSingleton(status);
    final api = FakeApi(syntheticZip());
    final storage = WeakStorage();
    final vm = GenerationPageViewmodel(
        apiService: api, generatedImageStorage: storage);
    final svc = await openService();
    final isolate = developer.Service.getIsolateId(Isolate.current)!;
    final control = sentinel();
    await svc.getAllocationProfile(isolate, gc: true);
    final before = await svc.getMemoryUsage(isolate);
    vm.startGeneration();
    await waitBatch(status);
    expect(api.calls, 250);
    expect(status.currentGenerationCount, 250);
    expect(status.commandList.length, 200);
    await svc.getAllocationProfile(isolate, gc: true);
    final memory = await svc.getMemoryUsage(isolate);
    final droppedAlive = alive(storage.refs, 50);
    final totalAlive = alive(storage.refs, 250);
    print('MEMORY_PROBE_BATCH ' +
        jsonEncode({
          'apiCalls': api.calls,
          'retainedHistory': status.commandList.length,
          'evictedPreviewsStillAliveAfterGC': droppedAlive,
          'totalPreviewsAlive': totalAlive,
          'previewBytesEach': storage.previewLength,
          'evictedPreviewBytes': storage.previewLength * droppedAlive,
          'sentinelCollected': control.target == null,
          'heapBefore': before.heapUsage,
          'externalBefore': before.externalUsage,
          'heapAfter': memory.heapUsage,
          'externalAfter': memory.externalUsage
        }));
    payload.settings.generationCount = 1;
    vm.startGeneration();
    await waitBatch(status);
    await svc.getAllocationProfile(isolate, gc: true);
    final afterRestart = alive(storage.refs, 50);
    print('MEMORY_PROBE_RESTART ' +
        jsonEncode({
          'evictedPreviewsStillAliveAfterNewBatch': afterRestart,
          'totalCalls': api.calls
        }));
    vm.dispose();
    await svc.dispose();
    await GetIt.I.reset();
    expect(control.target, isNull);
    expect(afterRestart, 0,
        reason: 'Control new batch clears logical task history');
    expect(droppedAlive, 0,
        reason:
            'Evicted first 50 results remain strongly held by completed logical tasks');
  });
  testWidgets('MEM02 result-key registry releases evicted image commands',
      (tester) async {
    await GetIt.I.reset();
    final payload = fixture();
    final status = CommandStatus();
    GetIt.I.registerSingleton(payload);
    GetIt.I.registerSingleton(status);
    final api = FakeApi(syntheticZip());
    final vm = GenerationPageViewmodel(
        apiService: api, generatedImageStorage: WeakStorage());
    Widget app(Widget child) => EasyLocalization(
        supportedLocales: const [Locale('en')],
        path: 'fixture',
        assetLoader: Loader(translations),
        saveLocale: false,
        startLocale: const Locale('en'),
        child: Builder(
            builder: (ctx) => MaterialApp(
                locale: ctx.locale,
                supportedLocales: ctx.supportedLocales,
                localizationsDelegates: ctx.localizationDelegates,
                home: child)));
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final svc = (await tester.runAsync(openService))!;
    final isolate = developer.Service.getIsolateId(Isolate.current)!;
    final sentinelRef = sentinel();
    await tester.pumpWidget(app(GenerationPageView(viewmodel: vm)));
    await tester.pumpAndSettle();
    final refs = <WeakReference<Command<void, InfoCardContent>>>[];
    final png =
        Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
    for (var i = 0; i < 220; i++) {
      addSyntheticCard(vm, refs, png, i);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.pumpAndSettle();
    expect(status.commandList.length, 200);
    expect(api.calls, 0);
    await tester.runAsync(() => svc.getAllocationProfile(isolate, gc: true));
    final retainedWhileMounted = aliveCommands(refs, 20);
    print('MEMORY_PROBE_KEYS_MOUNTED ' +
        jsonEncode({
          'cardsAdded': 220,
          'currentHistory': status.commandList.length,
          'evictedCommandsAlive': retainedWhileMounted,
          'sentinelCollected': sentinelRef.target == null,
          'apiCalls': api.calls
        }));
    await tester
        .pumpWidget(app(const Scaffold(body: Text('AWAY_FROM_RESULTS'))));
    await tester.pumpAndSettle();
    await tester.runAsync(() => svc.getAllocationProfile(isolate, gc: true));
    final retainedAfterUnmount = aliveCommands(refs, 20);
    print('MEMORY_PROBE_KEYS_UNMOUNTED ' +
        jsonEncode({
          'evictedCommandsAlive': retainedAfterUnmount,
          'currentHistory': status.commandList.length
        }));
    vm.dispose();
    await tester.runAsync(() => svc.dispose());
    await GetIt.I.reset();
    expect(sentinelRef.target, isNull);
    expect(retainedAfterUnmount, 0,
        reason: 'Unmounting the result page releases its key map');
    expect(retainedWhileMounted, 0,
        reason: 'The result page keeps evicted commands in its result-key map');
  });
}
