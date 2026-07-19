import 'package:flutter_command/flutter_command.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:nai_casrand/data/models/command_status.dart';
import 'package:nai_casrand/data/models/info_card_content.dart';
import 'package:nai_casrand/ui/generation_page/view_models/generation_page_viewmodel.dart';

void main() {
  setUp(() async {
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton(CommandStatus());
  });

  tearDown(() async {
    await GetIt.instance.reset();
  });

  test('adding a prompt command refreshes the generation page immediately', () {
    final viewmodel = GenerationPageViewmodel();
    var notificationCount = 0;
    viewmodel.addListener(() => notificationCount++);

    final command = Command.createSyncNoParam(
      () => const InfoCardContent(
        title: 'prompt',
        info: 'generated prompt',
        additionalInfo: {},
      ),
      initialValue: InfoCardContent.fromEmpty(),
    );

    viewmodel.addAndRunCommand(command);

    expect(viewmodel.commandList, contains(command));
    expect(notificationCount, 1);
    expect(command.value.title, 'prompt');
  });
}
