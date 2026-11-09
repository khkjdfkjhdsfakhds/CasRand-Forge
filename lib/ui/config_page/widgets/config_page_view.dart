import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/config_page/widgets/prompt_scheme_list_view.dart';
import 'package:nai_casrand/ui/navigation/widgets/image_import_area.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';

class ConfigPageView extends StatelessWidget {
  final ConfigPageViewmodel viewmodel;

  const ConfigPageView({super.key, required this.viewmodel});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewmodel.payloadConfig,
      builder: (context, _) => viewmodel.isFixedMode
          ? _FixedModeTabs(viewmodel: viewmodel)
          : PromptSchemeListView(viewmodel: viewmodel),
    );
  }
}

/// Fixed prompts are one separate set of inputs and keep the two page tabs.
class _FixedModeTabs extends StatelessWidget {
  const _FixedModeTabs({required this.viewmodel});

  final ConfigPageViewmodel viewmodel;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: TabBar(
            tabs: [
              Tab(text: tr('generation_prompt_config')),
              Tab(text: tr('generation_parameters')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ImageImportArea(
              ignoreWhenTextEditing: true,
              child: PromptTabView(
                viewmodel: viewmodel.activePromptViewmodel,
              ),
            ),
            ImageImportArea(
              child: ParametersConfigView(
                viewmodel: viewmodel.activeParametersViewmodel,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
