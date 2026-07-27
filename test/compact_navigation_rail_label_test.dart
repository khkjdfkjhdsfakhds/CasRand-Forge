import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/navigation/widgets/compact_navigation_rail_label.dart';

void main() {
  testWidgets('long navigation labels wrap without widening the rail', (
    tester,
  ) async {
    const label = 'Vibe Transfer / Precise Reference';
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: 0,
                labelType: NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.auto_awesome_motion_outlined),
                    label: CompactNavigationRailLabel(label: label),
                  ),
                ],
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final compactLabel = find.byType(CompactNavigationRailLabel);
    final text = tester.widget<Text>(
      find.descendant(of: compactLabel, matching: find.text(label)),
    );
    final tooltip = tester.widget<Tooltip>(
      find.descendant(of: compactLabel, matching: find.byType(Tooltip)),
    );

    expect(text.maxLines, 2);
    expect(text.softWrap, isTrue);
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.textAlign, TextAlign.center);
    expect(tooltip.message, label);
    expect(
      tester.getSize(find.byType(NavigationRail)).width,
      lessThanOrEqualTo(160),
    );
  });
}
