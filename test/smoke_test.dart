import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/views/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // TC-APP-BOOT-01: App boots to the home screen without exceptions.
  testWidgets('app boots to home screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FieldOpsApp()));
    await tester.pump();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('FieldOps Copilot'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Run self-test'), findsOneWidget);
  });
}
