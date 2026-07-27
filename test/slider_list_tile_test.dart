import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_casrand/ui/core/widgets/slider_list_tile.dart';

void main() {
  testWidgets('slider keeps a standard pointer target around the track', (
    tester,
  ) async {
    double? changedValue;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderListTile(
            title: 'Value',
            sliderValue: 0.5,
            min: 0,
            max: 1,
            divisions: 10,
            onChanged: (value) => changedValue = value,
          ),
        ),
      ),
    );

    final sliderRect = tester.getRect(find.byType(Slider));
    expect(sliderRect.height, greaterThanOrEqualTo(kMinInteractiveDimension));

    await tester.tapAt(
      Offset(sliderRect.left + sliderRect.width * 0.75, sliderRect.top + 4),
    );
    await tester.pump();

    expect(changedValue, isNotNull);
    expect(changedValue!, greaterThan(0.5));
  });

  testWidgets('range slider keeps a standard pointer target around the track', (
    tester,
  ) async {
    RangeValues? changedValues;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RangeListTile(
            title: 'Range',
            sliderStart: 0.25,
            sliderEnd: 0.75,
            min: 0,
            max: 1,
            divisions: 20,
            onChanged: (start, end) {
              changedValues = RangeValues(start, end);
            },
          ),
        ),
      ),
    );

    final sliderRect = tester.getRect(find.byType(RangeSlider));
    expect(sliderRect.height, greaterThanOrEqualTo(kMinInteractiveDimension));

    await tester.tapAt(
      Offset(sliderRect.left + sliderRect.width * 0.6, sliderRect.top + 4),
    );
    await tester.pump();

    expect(changedValues, isNotNull);
  });

  testWidgets('slider value can be entered and snaps to its configured step', (
    tester,
  ) async {
    double? changedValue;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderListTile(
            title: 'Strength: 0.50',
            sliderValue: 0.5,
            min: 0,
            max: 1,
            divisions: 10,
            inputKey: const Key('strength-input'),
            onChanged: (value) => changedValue = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Strength: 0.50'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('strength-input')), '0.74');
    await tester.tap(find.text('confirm'));
    await tester.pumpAndSettle();

    expect(changedValue, 0.7);
  });

  testWidgets('slider input rejects values outside its range', (tester) async {
    double? changedValue;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SliderListTile(
            title: 'Noise: 0.20',
            sliderValue: 0.2,
            min: 0,
            max: 1,
            divisions: 100,
            inputKey: const Key('noise-input'),
            onChanged: (value) => changedValue = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Noise: 0.20'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('noise-input')), '1.5');
    await tester.tap(find.text('confirm'));
    await tester.pump();

    expect(find.text('slider_invalid_value'), findsOneWidget);
    expect(changedValue, isNull);
  });

  testWidgets('range slider start and end can both be entered', (tester) async {
    RangeValues? changedValues;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RangeListTile(
            title: 'Range: -2 ~ 2',
            sliderStart: -2,
            sliderEnd: 2,
            min: -10,
            max: 10,
            divisions: 20,
            onChanged: (start, end) {
              changedValues = RangeValues(start, end);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Range: -2 ~ 2'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('range-slider-start-input')),
      '-4',
    );
    await tester.enterText(
      find.byKey(const Key('range-slider-end-input')),
      '5',
    );
    await tester.tap(find.text('confirm'));
    await tester.pumpAndSettle();

    expect(changedValues, const RangeValues(-4, 5));
  });
}
