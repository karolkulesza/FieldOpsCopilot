import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/views/diagnose_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// TC-APP-BOOT-01, retargeted at the real home screen.
///
/// The home screen is `DiagnoseScreen`, not the placeholder this test first
/// targeted. That makes it stronger, and it is worth saying why: it pumps the
/// app with **no overrides at all**, so every startup provider runs for real and
/// every one of them fails — `getApplicationSupportDirectory()` and the
/// model-status platform channel have no host implementation. The AC says "no
/// exceptions", and on this screen that is a real property rather than a
/// formality: a total startup failure has to arrive as rendered text rather than
/// as a thrown error or a grey screen.
void main() {
  testWidgets('app boots to the diagnose screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FieldOpsApp()));
    await tester.pump();

    expect(find.byType(DiagnoseScreen), findsOneWidget);
    expect(find.text('FieldOps Copilot'), findsWidgets);
    expect(find.byKey(DiagnoseKeys.inquiryField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Diagnose'), findsOneWidget);
  });

  // The half the old smoke test could not have: every platform dependency is
  // missing here, and the screen still has to be a screen. Without the startup
  // providers' `noRetry` policy this would also have sat in a loading state for
  // half a minute before settling.
  testWidgets('a host boot with no platform channels renders, does not throw', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: FieldOpsApp()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The button is inert, because nothing about this environment can diagnose.
    final button = tester.widget<FilledButton>(
      find.byKey(DiagnoseKeys.diagnoseButton),
    );
    expect(button.onPressed, isNull);
  });
}
