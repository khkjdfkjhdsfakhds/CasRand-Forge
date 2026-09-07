import 'dart:convert';
import 'package:nai_casrand/data/services/image_service.dart';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_view.dart';
import 'package:nai_casrand/ui/navigation/view_models/navigation_view_model.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/data/services/generated_image_storage.dart';
import 'package:nai_casrand/ui/i2i_page/view_models/i2i_page_viewmodel.dart';
import 'package:nai_casrand/data/use_cases/prepare_i2i_request_use_case.dart';
import 'image_storage_recovery_test.dart' as storage_probe;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_command/flutter_command.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/param_config.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/models/prompt_config.dart';
import 'package:nai_casrand/data/models/settings.dart';
import 'package:nai_casrand/data/models/precise_reference_config.dart';
import 'package:nai_casrand/data/use_cases/prepare_director_tool_request_use_case.dart';
import 'package:nai_casrand/ui/enhance_page/view_models/enhance_page_viewmodel.dart';
import 'package:nai_casrand/ui/enhance_page/widgets/enhance_page_view.dart';
import 'package:nai_casrand/ui/director_page/view_models/director_page_viewmodel.dart';
import 'package:nai_casrand/ui/director_page/widgets/director_page_view.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/core/widgets/image_transform_workspace.dart';

PayloadConfig payload() => PayloadConfig(
    rootPromptConfig: PromptConfig(strs: [], prompts: []),
    negativePromptConfig: PromptConfig(strs: [], prompts: []),
    characterConfigList: [],
    savedPromptConfigList: [],
    paramConfig: ParamConfig(model: 'nai-diffusion-4-5-full'),
    settings: Settings.fromJson({}),
    overridePrompt: 'USER_CURRENT_PROMPT',
    useOverridePrompt: true,
    useCharacterPromptWithOverride: false);
Uint8List png(int red, {bool metadata = false}) {
  final im = img.Image(width: 64, height: 64, numChannels: 3);
  img.fill(im, color: img.ColorRgb8(red, 40, 120));
  if (metadata) {
    im.addTextData({
      'Software': 'NovelAI',
      'Source': 'NovelAI Diffusion V5',
      'Description': 'IMPORTED_PROMPT',
      'Comment':
          jsonEncode({'prompt': 'IMPORTED_PROMPT', 'steps': 29, 'seed': 12})
    });
  }
  return Uint8List.fromList(img.encodePng(im));
}

Uint8List portraitExifJpeg() {
  final im = img.Image(width: 400, height: 200, numChannels: 3);
  img.fillRect(im,
      x1: 0, y1: 0, x2: 199, y2: 199, color: img.ColorRgb8(240, 20, 20));
  img.fillRect(im,
      x1: 200, y1: 0, x2: 399, y2: 199, color: img.ColorRgb8(20, 20, 240));
  im.exif.imageIfd.orientation = 6;
  return Uint8List.fromList(img.encodeJpg(im, quality: 100));
}

class NoApiGeneration extends GenerationPageViewmodel {
  @override
  Future<void> refreshSubscriptionSnapshot() async {}
}

class Words extends AssetLoader {
  final Map<String, dynamic> words;
  Words(this.words);
  @override
  Future<Map<String, dynamic>> load(String p, Locale l) async => words;
}

class ExitShell extends NavigationView {
  ExitShell({super.key}) : super(viewModel: NavigationViewModel());
  @override
  NavigationViewState createState() => ExitShellState();
}

class ExitShellState extends NavigationViewState {
  @override
  Widget build(BuildContext c) => const Scaffold(body: Text('EXIT_FIXTURE'));
}

class FixtureConfigs extends ConfigService {
  FixtureConfigs() {
    packageInfo = PackageInfo(
        appName: 'Fixture',
        packageName: 'fixture',
        version: 'FIXTURE',
        buildNumber: '1');
  }
  @override
  Future<void> saveConfig(Map<String, dynamic> jsonData) async {}
  @override
  Future<void> flush() async {}
}

void main() {
  late Map<String, dynamic> words;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/shared_preferences'),
            (c) async => c.method == 'getAll' ? <String, Object>{} : true);
    await EasyLocalization.ensureInitialized();
    words = jsonDecode(await rootBundle.loadString('assets/l10n/en.json'));
  });
  setUp(() async {
    await GetIt.I.reset();
    GetIt.I.registerSingleton<PayloadConfig>(payload());
    GetIt.I.registerSingleton(CommandStatus());
    GetIt.I.registerSingleton(NavigationRequest());
    GetIt.I.registerSingleton<GenerationPageViewmodel>(NoApiGeneration());
  });
  tearDown(() async {
    await GetIt.I.reset();
    debugDefaultTargetPlatformOverride = null;
  });
  Widget app(Widget home) => EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'fixture',
      assetLoader: Words(words),
      saveLocale: false,
      startLocale: const Locale('en'),
      child: Builder(
          builder: (c) => MaterialApp(
              localizationsDelegates: c.localizationDelegates,
              supportedLocales: c.supportedLocales,
              locale: c.locale,
              home: home)));
  test(
      'IMG-03 removing Enhance image during metadata load must invalidate the pending import',
      () async {
    final p = GetIt.I<PayloadConfig>();
    final vm = EnhancePageViewmodel();
    final importing = vm.loadImageBytes(png(40, metadata: true));
    expect(p.enhanceConfig.hasImage, isTrue);
    vm.removeImage();
    expect(p.overridePrompt, 'USER_CURRENT_PROMPT');
    await importing;
    debugPrint(
        'IMG-03 source=${p.enhanceConfig.hasImage} prompt=${p.overridePrompt} importedNotice=${vm.takeLastImportActivatedFixedMode()}');
    expect(p.enhanceConfig.hasImage, isFalse);
    expect(p.overridePrompt, 'USER_CURRENT_PROMPT',
        reason:
            'A cancelled source must not later overwrite current generation metadata.');
  });
  for (final isEnhance in [true, false]) {
    testWidgets(
        'IMG-04 gallery handoff clears stale result isEnhance=$isEnhance',
        (tester) async {
      final p = GetIt.I<PayloadConfig>();
      final g = GetIt.I<GenerationPageViewmodel>();
      final before = png(10);
      final result = png(60);
      final next = png(240);
      final old = InfoCardContent(
          title: 'OLD_RESULT',
          info: '',
          additionalInfo: const {},
          imageBytes: result);
      final command = Command.createAsyncNoParam<InfoCardContent>(
          () async => old,
          initialValue: old);
      if (isEnhance) {
        p.enhanceConfig.setImage(before);
        g.lastEnhanceCommand = command;
      } else {
        p.directorToolConfig.setImage(before);
        g.lastDirectorCommand = command;
      }
      final handoff = ImageHandoffCoordinator(
          payloadConfig: p,
          navigation: GetIt.I<NavigationRequest>(),
          readDimensions: (_) async =>
              const ImageDimensions(width: 64, height: 64));
      GetIt.I.registerSingleton(handoff);
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(isEnhance
          ? EnhancePageView(viewmodel: EnhancePageViewmodel())
          : DirectorPageView(viewmodel: DirectorPageViewmodel())));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ImageTransformWorkspace>(
                  find.byType(ImageTransformWorkspace))
              .result
              ?.imageBytes,
          result);
      if (isEnhance) {
        handoff.sendToEnhance(next, metadata: const {}, prompt: 'NEXT_SOURCE');
      } else {
        handoff.sendToDirectorTools(next);
      }
      await tester.pump();
      await tester.pumpAndSettle();
      final workspace = tester.widget<ImageTransformWorkspace>(
          find.byType(ImageTransformWorkspace));
      expect(workspace.sourceBytes, next);
      debugPrint(
          'IMG-04 isEnhance=$isEnhance sourceChanged=${listEquals(workspace.sourceBytes, next)} result=${workspace.result?.title}');
      final stale = workspace.result;
      await tester.pumpWidget(const SizedBox());
      command.dispose();
      handoff.dispose();
      await tester.pump(const Duration(milliseconds: 60));
      expect(stale, isNull,
          reason:
              'Original/result workspace must not pair a new original with a result generated from the old original.');
    });
  }
  test('IMG-05 Precise Reference respects EXIF-oriented portrait geometry',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final bytes = portraitExifJpeg();
    final reference =
        await PreciseReferenceConfig.fromBytes(bytes, 'ROTATED_FIXTURE.jpg');
    final output = img.decodePng(reference.imageBytes)!;
    debugPrint(
        'IMG-05 precise output=${output.width}x${output.height} bakedSource=${img.bakeOrientation(img.decodeJpg(bytes)!).width}x${img.bakeOrientation(img.decodeJpg(bytes)!).height}');
    expect(output.height, greaterThan(output.width),
        reason:
            'EXIF orientation 6 displays a portrait but reference canvas is chosen from unrotated dimensions.');
  });
  test(
      'IMG-05B Director resized request respects EXIF-oriented portrait geometry',
      () async {
    final p = GetIt.I<PayloadConfig>();
    final bytes = portraitExifJpeg();
    DirectorPageViewmodel().loadImageBytes(bytes);
    final c = p.directorToolConfig;
    final request = await const PrepareDirectorToolRequestUseCase()(
        imageBytes: bytes, width: c.width, height: c.height);
    final output = img.decodePng(base64Decode(request.imageB64))!;
    debugPrint(
        'IMG-05B config=${c.width}x${c.height} request=${request.width}x${request.height} PNG=${output.width}x${output.height}');
    expect(output.height, greaterThan(output.width));
  });
  test(
      'IMG-05C ordinary I2I automatic sizing respects EXIF-oriented portrait geometry',
      () async {
    final p = GetIt.I<PayloadConfig>();
    final bytes = portraitExifJpeg();
    I2iPageViewmodel().loadImageBytes(bytes);
    final c = p.i2iConfig;
    final request = await PrepareI2iRequestUseCase(config: c)(
        targetWidth: c.requestSize.width, targetHeight: c.requestSize.height);
    debugPrint(
        'IMG-05C original header=${c.width}x${c.height} automatic=${c.requestSize.width}x${c.requestSize.height} request=${request!.width}x${request.height}');
    expect(request.height, greaterThan(request.width));
  });
  testWidgets(
      'IMG-01B actual exit callback must not approve exit with an unsaved PNG',
      (tester) async {
    final p = GetIt.I<PayloadConfig>();
    p.settings.welcomeMessageVersion = 'FIXTURE';
    GetIt.I.registerSingleton<ConfigService>(FixtureConfigs());
    late Directory dir;
    late storage_probe.DelayedFileService files;
    late GeneratedImageStorageService storage;
    late GeneratedImageStorageSubmission submitted;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('casrand-actual-exit-');
      files = storage_probe.DelayedFileService();
      storage = GeneratedImageStorageService(
          desktopJpegSupported: true, fileService: files);
      submitted = storage.submit(storage_probe.request(png(120), dir.path));
      await files.started.future;
    });
    GetIt.I.registerSingleton(storage);
    await tester.pumpWidget(app(ExitShell()));
    await tester.pumpAndSettle();
    final state = tester.state<ExitShellState>(find.byType(ExitShell));
    AppExitResponse? outcome;
    final exit = state.didRequestAppExit().then((value) => outcome = value);
    await tester.pumpAndSettle();
    expect(outcome, isNull,
        reason: 'Pending PNG must first show the storage exit prompt.');
    await tester.tap(find.widgetWithText(
        FilledButton, words['jpeg_storage_exit_wait'] as String));
    await tester.pump();
    expect(outcome, isNull);
    expect(files.written, isFalse);
    await tester.runAsync(() async {
      files.release.complete();
      await submitted.completed;
    });
    await tester.pumpAndSettle();
    await exit;
    expect(outcome, AppExitResponse.exit);
    expect(files.written, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => dir.delete(recursive: true));
  });
  for (final description in [null, '']) {
    test(
        'IMG-06 generation metadata without a positive Description remains importable description=$description',
        () async {
      final im = img.Image(width: 64, height: 64, numChannels: 3);
      im.addTextData({
        'Software': 'NovelAI',
        'Source': 'NovelAI Diffusion V5 0ADF9AB7',
        if (description != null) 'Description': description,
        'Comment': jsonEncode({
          'steps': 28,
          'seed': 42,
          'sampler': 'k_euler_ancestral',
          'v4_prompt': {
            'caption': {'base_caption': '', 'char_captions': []}
          }
        })
      });
      final bytes = Uint8List.fromList(img.encodePng(im));
      final loaded = await ImageService().extractMetadataFromBytes(bytes);
      debugPrint('IMG-06 Description=$description extracted=$loaded');
      expect(loaded, isNotNull,
          reason:
              'Software/Comment identify a valid generation record, and missing prompt is an intentional clear rather than absent metadata.');
    });
  }

  test('IMG-05D Enhance source import respects EXIF-oriented portrait geometry',
      () async {
    final vm = EnhancePageViewmodel();
    await vm.loadImageBytes(portraitExifJpeg());
    debugPrint(
        'IMG-05D source=${vm.config.width}x${vm.config.height} target=${vm.targetSize.width}x${vm.targetSize.height}');
    expect(vm.targetSize.height, greaterThan(vm.targetSize.width));
  });
  test('control import model supports clearing a missing positive prompt', () {
    final p = GetIt.I<PayloadConfig>();
    p.importMetadataToFixedProfile(
        {'steps': 28, 'seed': 42, 'sampler': 'k_euler_ancestral'});
    expect(p.overridePrompt, '');
    expect(p.paramConfig.seed, 42);
  });

  test('IMG-03 replacement without metadata does not commit the first import',
      () async {
    final p = GetIt.I<PayloadConfig>();
    final vm = EnhancePageViewmodel();
    final first = vm.loadImageBytes(png(20, metadata: true));
    final next = png(200);
    final second = vm.loadImageBytes(next);
    expect(await first, isFalse);
    expect(await second, isTrue);
    expect(p.enhanceConfig.imageBytes, same(next));
    expect(p.overridePrompt, 'USER_CURRENT_PROMPT');
    expect(vm.takeLastImportActivatedFixedMode(), isFalse);
    vm.dispose();
  });
  test('IMG-03 disposing the importing view model invalidates late metadata',
      () async {
    final p = GetIt.I<PayloadConfig>();
    final vm = EnhancePageViewmodel();
    final importing = vm.loadImageBytes(png(20, metadata: true));
    vm.dispose();
    expect(await importing, isFalse);
    expect(p.overridePrompt, 'USER_CURRENT_PROMPT');
  });
  for (final isEnhance in [true, false]) {
    testWidgets(
        'IMG-04 reopened tool does not restore a result from a replaced source isEnhance=$isEnhance',
        (tester) async {
      final p = GetIt.I<PayloadConfig>();
      final g = GetIt.I<GenerationPageViewmodel>();
      final old = InfoCardContent(
          title: 'HISTORICAL_RESULT',
          info: '',
          additionalInfo: const {},
          imageBytes: png(40));
      final command = Command.createAsyncNoParam<InfoCardContent>(
          () async => old,
          initialValue: old);
      g.commandList.add(command);
      if (isEnhance) {
        p.enhanceConfig.setImage(png(20));
        g.lastEnhanceCommand = command;
      } else {
        p.directorToolConfig.setImage(png(20));
        g.lastDirectorCommand = command;
      }
      final handoff = ImageHandoffCoordinator(
          payloadConfig: p,
          navigation: GetIt.I<NavigationRequest>(),
          readDimensions: (_) async =>
              const ImageDimensions(width: 64, height: 64));
      GetIt.I.registerSingleton(handoff);
      await tester.pumpWidget(const SizedBox());
      if (isEnhance) {
        handoff.sendToEnhance(png(200), metadata: const {});
      } else {
        handoff.sendToDirectorTools(png(200));
      }
      tester.binding.scheduleFrame();
      await tester.pumpAndSettle();
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app(isEnhance
          ? EnhancePageView(viewmodel: EnhancePageViewmodel())
          : DirectorPageView(viewmodel: DirectorPageViewmodel())));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<ImageTransformWorkspace>(
                  find.byType(ImageTransformWorkspace))
              .result,
          isNull);
      expect(g.commandList, contains(command));
      expect(command.value, same(old));
      if (isEnhance) {
        p.enhanceConfig.removeImage();
      } else {
        p.directorToolConfig.removeImage();
      }
      await tester.pump();
      expect(
          tester
              .widget<ImageTransformWorkspace>(
                  find.byType(ImageTransformWorkspace))
              .sourceBytes,
          isNull);
      await tester.pumpWidget(const SizedBox());
      command.dispose();
      handoff.dispose();
      await tester.pump(const Duration(milliseconds: 60));
    });
  }
}
