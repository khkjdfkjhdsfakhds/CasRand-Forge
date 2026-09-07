import 'package:flutter/material.dart';
import 'package:nai_casrand/ui/i2i_tab/view_models/i2i_tab_viewmodel.dart';
import 'package:nai_casrand/ui/i2i_tab/widgets/i2i_tab_view.dart';

/// Top-level Vibe Transfer / Precise Reference workspace.
///
/// These controls affect ordinary generation, but no longer compete for space
/// with the prompt-randomisation and generation-parameter tabs.
class VibeReferencePageView extends StatelessWidget {
  const VibeReferencePageView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: I2iTabView(viewmodel: I2iTabViewmodel()),
    );
  }
}
