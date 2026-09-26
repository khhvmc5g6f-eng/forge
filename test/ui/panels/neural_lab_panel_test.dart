import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/ui/panels/neural_lab/neural_lab_panel.dart';

void main() {
  // The panel runs an animation Ticker, which schedules frames continuously,
  // so these tests pump fixed frame steps instead of pumpAndSettle.
  //
  // The test viewport is made tall so the analytics dock's lazily-built
  // ListView constructs every card.
  Future<void> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: NeuralLabPanel())));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('Neural Lab panel renders 3D stage, controls and analytics dock',
      (tester) async {
    await pumpPanel(tester);

    expect(find.text('Train'), findsOneWidget);
    expect(find.text('Step'), findsOneWidget);
    expect(find.text('Surface'), findsOneWidget);
    expect(find.text('Rotate'), findsOneWidget);
    expect(find.text('?'), findsOneWidget);
    // analytics dock cards are present
    expect(find.text('LOSS CURVES'), findsOneWidget);
    expect(find.text('DECISION BOUNDARY'), findsOneWidget);
    expect(find.text('GRADIENT FLOW'), findsOneWidget);
    expect(find.text('CONFUSION MATRIX'), findsOneWidget);
    // initial phase (embedded in the accuracy readout, e.g. "0.0% · idle")
    expect(find.textContaining('idle'), findsWidgets);
  });

  testWidgets('pressing Train runs steps and updates metrics without throwing',
      (tester) async {
    await pumpPanel(tester);

    // The toolbar scrolls horizontally — bring Train into view before tapping.
    await tester.ensureVisible(find.text('Train'));
    await tester.tap(find.text('Train'));
    // Let several frames of the ticker run with training active.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.ensureVisible(find.text('Pause'));
    await tester.tap(find.text('Pause'));
    // Let any in-flight pulse waves expire.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Some training happened and the accuracy readout advanced beyond idle
    // (phase is embedded in the combined accuracy string).
    expect(find.textContaining('learning'), findsWidgets);
  });
}
