import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/core/constants/app_identity.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/image_handoff_coordinator.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/data/models/payload_config.dart';
import 'package:nai_casrand/data/services/config_service.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';
import 'package:nai_casrand/ui/navigation/widgets/navigation_view.dart';
import 'package:nai_casrand/ui/navigation/view_models/navigation_view_model.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:get_it/get_it.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();

  GetIt.instance.registerLazySingleton<ConfigService>(() => ConfigService());
  final configService = GetIt.instance<ConfigService>();
  configService.packageInfo = await PackageInfo.fromPlatform();
  final savedConfig = await configService.loadSavedConfig();

  GetIt.instance
      .registerLazySingleton(() => PayloadConfig.fromJson(savedConfig));
  GetIt.instance.registerLazySingleton(() => CommandStatus());
  GetIt.instance.registerLazySingleton(() => NavigationRequest());
  GetIt.instance.registerLazySingleton(
    () => ImageHandoffCoordinator(
      payloadConfig: GetIt.I<PayloadConfig>(),
      navigation: GetIt.I<NavigationRequest>(),
    ),
  );

  GetIt.instance.registerLazySingleton(() => GenerationPageViewmodel());

  final appWithLocales = EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/l10n',
    child: const MyApp(),
  );

  runApp(appWithLocales);
}

/// App-wide look: soft elevation-free cards on a layered surface, rounded
/// corners everywhere, and a quiet navigation rail — closer to the official
/// web editor's calm panel look while keeping the CasRand pink identity.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Colors.pinkAccent,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainer,
      scrolledUnderElevation: 0,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.primaryContainer,
      indicatorShape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final config = GetIt.I<PayloadConfig>();
    return AdaptiveTheme(
      light: buildAppTheme(Brightness.light),
      dark: buildAppTheme(Brightness.dark),
      initial: config.settings.theme,
      builder: (theme, darkTheme) => MaterialApp(
        title: appDisplayName,
        theme: theme,
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        home: NavigationView(viewModel: NavigationViewModel()),
      ),
    );
  }
}
