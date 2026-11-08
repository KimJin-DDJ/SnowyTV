import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/widget/tv_focus_overlay.dart';

void main() {
  testWidgets('D-pad focus moves without scheduling frames while idle',
      (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => TvFocusOverlay(child: child!),
      home: Scaffold(
        body: Row(children: [
          TextButton(
            autofocus: true,
            focusNode: first,
            onPressed: () {},
            child: const Text('Back'),
          ),
          TextButton(
            focusNode: second,
            onPressed: () {},
            child: const Text('Continue'),
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(first.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(second.hasPrimaryFocus, isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
