import 'package:field_ops_copilot/app.dart';
import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/viewmodels/work_order_form_viewmodel.dart';
import 'package:field_ops_copilot/views/components/clarification_dialog.dart';
import 'package:field_ops_copilot/views/components/work_order_form_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// TC-UI-CLAR-01 on hardware — the clarification overlay under a real finger.
///
/// ```sh
/// flutter test integration_test/clarification_test.dart -d <device>
///
/// # Wirelessly tethered iOS device: `flutter test` cannot launch there and has
/// # no `--publish-port` flag despite the error suggesting one.
/// flutter run integration_test/clarification_test.dart -d <device> --publish-port
/// ```
///
/// **No models and no `--dart-define`s.** This is deliberately not an agent test:
/// the question is scripted straight into the real form viewmodel, which is
/// exactly how `record_work_order_fields` delivers one in production — the
/// `asked` half of a payload the screen already parses.
///
/// **What this proves, and what it does not.** It proves the overlay renders on a
/// real panel, that its buttons are hittable at the size a thumb arrives at, and
/// that a tap lands the chosen value in the field — none of which a host widget
/// test can claim, because a host test has no panel and no finger. It proves
/// **nothing** about whether the model ever asks.
///
/// That distinction is not hedging; it is the finding this file exists beside.
/// Two prompts designed to force an ambiguity were run against Gemma 4 E2B on the
/// demo iPad, and both times it asked in **prose** instead of through the tool's
/// `clarification` argument. The second one is the sharper result: given a
/// genuinely ambiguous door fault it *both* guessed (recording `E-305` and
/// `BELT-330-DRV`) *and* then asked the technician which part they had fitted —
/// the two things the argument exists to prevent, in one turn.
///
/// So the modal is verified as a UI and unverified as an *interaction*, and the
/// sprint plan says so in those words. A test that pretended otherwise by driving
/// the model until it happened to comply would be measuring the prompt it took to
/// get there.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The payload shape the tool really emits: a recording *and* a question, on
  /// one call. Built through the tool's own key constants so a rename of either
  /// breaks this rather than silently making it script a payload nothing sends.
  Map<String, Object?> payloadWithQuestion() => const {
    RecordWorkOrderFieldsTool.recordedKey: {'fault_code': 'E-305'},
    RecordWorkOrderFieldsTool.askedKey: {
      'field': 'required_parts',
      'question': 'Which door part did you fit?',
      'options': ['BELT-330-DRV', 'SNS-770-OPT'],
    },
  };

  Future<ProviderContainer> pumpApp(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const FieldOpsApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('TC-UI-CLAR-01 — the question opens over the screen', (
    tester,
  ) async {
    final container = await pumpApp(tester);

    container
        .read(workOrderFormProvider.notifier)
        .applyPayload(payloadWithQuestion());
    await tester.pumpAndSettle();

    expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);
    expect(find.text('Which door part did you fit?'), findsOneWidget);
    expect(find.byKey(ClarificationKeys.option(0)), findsOneWidget);
    expect(find.byKey(ClarificationKeys.option(1)), findsOneWidget);

    // The recording on the same call still landed — the question is additional
    // to the fields, not instead of them.
    expect(
      container.read(workOrderFormProvider).textOf(WorkOrderField.faultCode),
      'E-305',
    );
  });

  testWidgets('an option is big enough to hit, and hitting it fills the field', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    container
        .read(workOrderFormProvider.notifier)
        .applyPayload(payloadWithQuestion());
    await tester.pumpAndSettle();

    // **The assertion a host test cannot make.** Apple's HIG puts the minimum
    // target at 44pt square, and this is the one place the real device metrics
    // are in play. A button that renders but is 20pt tall is a question a
    // technician in gloves cannot answer.
    final size = tester.getSize(find.byKey(ClarificationKeys.option(0)));
    expect(
      size.height,
      greaterThanOrEqualTo(44),
      reason: 'below the HIG minimum this is unhittable in the field',
    );

    await tester.tap(find.byKey(ClarificationKeys.option(1)));
    await tester.pumpAndSettle();

    expect(find.byKey(ClarificationKeys.dialog), findsNothing);
    expect(
      container
          .read(workOrderFormProvider)
          .textOf(WorkOrderField.requiredParts),
      'SNS-770-OPT',
      reason: 'the answer fills the field it was asked about',
    );
    // And the controller, which is what the technician actually reads.
    expect(
      tester
          .widget<TextField>(
            find.byKey(WorkOrderKeys.field(WorkOrderField.requiredParts)),
          )
          .controller!
          .text,
      'SNS-770-OPT',
    );
  });

  testWidgets('dismissing leaves the field alone', (tester) async {
    // Dismissal is a first-class outcome, as the dialog's own library doc argues:
    // a technician who does not know which part they fitted must be able to say
    // nothing, and saying nothing must not write a guess into a work order.
    final container = await pumpApp(tester);
    container
        .read(workOrderFormProvider.notifier)
        .applyPayload(payloadWithQuestion());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(ClarificationKeys.dismiss));
    await tester.pumpAndSettle();

    expect(find.byKey(ClarificationKeys.dialog), findsNothing);
    expect(
      container
          .read(workOrderFormProvider)
          .textOf(WorkOrderField.requiredParts),
      '',
    );
    expect(
      container.read(workOrderFormProvider).clarification,
      isNull,
      reason: 'a dismissed question must not reopen on the next rebuild',
    );
  });
}
