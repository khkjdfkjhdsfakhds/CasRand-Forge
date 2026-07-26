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
}
