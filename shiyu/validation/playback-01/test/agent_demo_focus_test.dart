import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiyu_playback_probe/client_agent_demo.dart';

Widget routeApp() =>
    const MaterialApp(home: Scaffold(body: Text('Original controlled render')));

void main() {
  testWidgets(
    'normal MaterialApp route is a positive control for real view-focus request',
    (tester) async {
      tester.platformDispatcher.resetFocusedViewTestValues();
      await tester.pumpWidget(routeApp());
      await tester.pumpAndSettle();
      expect(
        tester.platformDispatcher.testFocusEvents.where(
          (e) => e.state == ui.ViewFocusState.focused,
        ),
        isNotEmpty,
      );
      expect(
        FocusManager.instance.primaryFocus,
        isNot(FocusManager.instance.rootScope),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      tester.platformDispatcher.resetFocusedViewTestValues();
    },
  );

  testWidgets(
    'debug demo boundary prevents initial route requesting native view focus',
    (tester) async {
      tester.platformDispatcher.resetFocusedViewTestValues();
      await tester.pumpWidget(agentDemoFocusBoundary(routeApp()));
      await tester.pumpAndSettle();
      expect(
        tester.platformDispatcher.testFocusEvents.where(
          (e) => e.state == ui.ViewFocusState.focused,
        ),
        isEmpty,
      );
      expect(
        FocusManager.instance.primaryFocus,
        FocusManager.instance.rootScope,
      );
      expect(find.text('Original controlled render'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.platformDispatcher.resetFocusedViewTestValues();
    },
  );
}
