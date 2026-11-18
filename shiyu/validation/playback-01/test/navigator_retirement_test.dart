// Test the actual barrier component above a real Navigator/modal route. The
// native AppOwner placement is independently source-reviewed, not faked here.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiyu_playback_probe/client_command_barrier.dart';

void main() {
  testWidgets('retiring the Navigator disables modal pointer focused intents and semantics', (tester) async {
    final frozen = ValueNotifier(false), focus = FocusNode();
    final semantics = tester.ensureSemantics();
    var actions = 0;
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => ValueListenableBuilder<bool>(valueListenable: frozen,
        builder: (_, retired, navigator) => ClientCommandBarrier(
            frozen: retired, child: navigator!), child: child),
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => showDialog<void>(context: context,
          builder: (_) => AlertDialog(content: FilledButton(focusNode: focus,
            autofocus: true, onPressed: () { actions++; },
            child: const Text('Modal candidate action')))),
        child: const Text('Open owned modal')))),
    ));
    try {
      await tester.tap(find.text('Open owned modal')); await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      expect(find.semantics.byLabel('Modal candidate action'), findsOneWidget);
      Actions.invoke(focus.context!, const ActivateIntent());
      expect(actions, 1, reason: 'The modal actually had an enabled activation action');
      frozen.value = true;
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      await tester.tap(find.text('Modal candidate action'), warnIfMissed: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      final currentFocus = FocusManager.instance.primaryFocus?.context;
      if (currentFocus != null) Actions.maybeInvoke(currentFocus, const ActivateIntent());
      await tester.pump();
      expect(actions, 1,
          reason: 'Pointer, keyboard and currently focused intent dispatch cannot reach the retired modal');
      expect(find.semantics.byLabel('Modal candidate action'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose(); focus.dispose(); frozen.dispose();
    }
  });
}
