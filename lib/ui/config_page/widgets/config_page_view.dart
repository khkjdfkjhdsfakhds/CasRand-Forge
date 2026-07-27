import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/config_page/view_models/config_page_viewmodel.dart';
import 'package:nai_casrand/ui/parameters_config/widgets/parameters_conifg_view.dart';
import 'package:nai_casrand/ui/parameters_config/view_models/parameters_config_viewmodel.dart';
import 'package:nai_casrand/ui/prompt_tab/widgets/prompt_tab_view.dart';
import 'package:nai_casrand/ui/prompt_tab/view_models/prompt_tab_viewmodel.dart';

class ConfigPageView extends StatelessWidget {
  final ConfigPageViewmodel viewmodel;

  const ConfigPageView({super.key, required this.viewmodel});

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
              PromptTabView(
                  viewmodel: PromptTabViewmodel(
                payloadConfig: viewmodel.payloadConfig,
              )),
              ParametersConfigView(
                viewmodel: ParametersConfigViewmodel(),
              ),
            ],
          )),
    );
  }
}
