import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:field_ops_copilot/services/ai/tools/record_work_order_fields_tool.dart';
import 'package:field_ops_copilot/viewmodels/work_order_form_viewmodel.dart';
import 'package:field_ops_copilot/views/components/clarification_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The AC's input verbatim: `["12-inch mesh","14-inch carbon"]`.
  const request = ClarificationRequest(
    field: WorkOrderField.requiredParts,
    question:
        'Which filter did you use: the 12-inch mesh or the 14-inch '
        'carbon?',
    options: ['12-inch mesh', '14-inch carbon'],
  );

  group('TC-UI-CLAR-01: clarification render', () {
    testWidgets('the overlay offers one tappable option per answer', (
      tester,
    ) async {
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: ClarificationDialog(
            request: request,
            onChosen: (choice) => chosen = choice,
            onDismissed: () {},
          ),
        ),
      );

      // Two options → two tappable buttons. Found by *role* (a button widget)
      // rather than by `find.text`, because a `Text` also matches the question
      // above them — which quotes both options, so a text-based count would read
      // as four and pass for the wrong reason.
      final options = find.descendant(
        of: find.byKey(ClarificationKeys.dialog),
        matching: find.byType(OutlinedButton),
      );
      expect(options, findsNWidgets(2));

      for (var i = 0; i < request.options.length; i++) {
        final option = find.byKey(ClarificationKeys.option(i));
        expect(option, findsOneWidget, reason: 'option $i');
        expect(
          tester.widget<OutlinedButton>(option).onPressed,
          isNotNull,
          reason: 'option $i must be tappable',
        );
        expect(
          find.descendant(of: option, matching: find.text(request.options[i])),
          findsOneWidget,
        );
      }

      await tester.tap(find.byKey(ClarificationKeys.option(1)));
      expect(chosen, '14-inch carbon');
    });

    testWidgets('the question and the field label are both shown', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ClarificationDialog(
            request: request,
            onChosen: (_) {},
            onDismissed: () {},
          ),
        ),
      );

      expect(
        tester.widget<Text>(find.byKey(ClarificationKeys.question)).data,
        request.question,
      );
      // The field label, so a technician knows which of four boxes this is about.
      expect(find.text(WorkOrderField.requiredParts.label), findsOneWidget);
    });

    testWidgets('a three-option question renders three', (tester) async {
      const three = ClarificationRequest(
        field: WorkOrderField.requiredParts,
        question: 'Which one?',
        options: ['12-inch mesh', '14-inch carbon', '16-inch pleated'],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ClarificationDialog(
            request: three,
            onChosen: (_) {},
            onDismissed: () {},
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(ClarificationKeys.dialog),
          matching: find.byType(OutlinedButton),
        ),
        findsNWidgets(3),
      );
      expect(find.byKey(ClarificationKeys.option(2)), findsOneWidget);
    });

    testWidgets('dismissing reports no choice', (tester) async {
      var dismissed = false;
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: ClarificationDialog(
            request: request,
            onChosen: (choice) => chosen = choice,
            onDismissed: () => dismissed = true,
          ),
        ),
      );

      await tester.tap(find.byKey(ClarificationKeys.dismiss));

      expect(dismissed, isTrue);
      expect(chosen, isNull);
    });
  });

  group('ClarificationHost', () {
    /// Pumps a host over a trivial child and returns the container driving it.
    Future<ProviderContainer> pumpHost(WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ClarificationHost(child: Text('behind'))),
          ),
        ),
      );
      return container;
    }

    /// Records a clarification the way the agent does — through the tool payload,
    /// so this exercises the same path the run does rather than a shortcut.
    void ask(ProviderContainer container) {
      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: <String, Object?>{},
        RecordWorkOrderFieldsTool.askedKey: {
          'field': 'required_parts',
          'question': 'Which filter did you use?',
          'options': ['12-inch mesh', '14-inch carbon'],
        },
      });
    }

    testWidgets('nothing is shown until the agent asks', (tester) async {
      await pumpHost(tester);

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      expect(find.text('behind'), findsOneWidget);
    });

    testWidgets('a pending question opens the overlay', (tester) async {
      final container = await pumpHost(tester);

      ask(container);
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);
    });

    testWidgets('choosing fills the field and closes the overlay', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ClarificationKeys.option(0)));
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      final state = container.read(workOrderFormProvider);
      expect(state.textOf(WorkOrderField.requiredParts), '12-inch mesh');
      expect(state.clarification, isNull);
      expect(
        state.fields[WorkOrderField.requiredParts]!.origin,
        FormFieldOrigin.clarification,
      );
    });

    testWidgets('dismissing closes the question without filling', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ClarificationKeys.dismiss));
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      final state = container.read(workOrderFormProvider);
      expect(state.textOf(WorkOrderField.requiredParts), '');
      expect(
        state.clarification,
        isNull,
        reason: 'a dismissed question must not reopen on the next rebuild',
      );
    });

    testWidgets('tapping the barrier is the same as dismissing', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();

      // Top-left is outside the dialog on every reasonable layout.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      expect(container.read(workOrderFormProvider).clarification, isNull);
      expect(
        container
            .read(workOrderFormProvider)
            .textOf(WorkOrderField.requiredParts),
        '',
      );
    });

    // The third state the host's doc names: a request cleared while the dialog is
    // up. Without the pop, the technician is left answering a question about a
    // form that has moved on — and answering it would write into a field the reset
    // just emptied.
    testWidgets('clearing the request under an open overlay pops it', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();
      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);

      container.read(workOrderFormProvider.notifier).reset();
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
    });

    // The gap the host's `_showing` notifier exists to close, and it is not
    // hypothetical: `AgentLoop` runs up to four turns and each may call the tool.
    // With a route built around the request it was pushed with, the technician
    // reads the *first* question while the state holds the second — so a tap
    // writes the option they read into the field they were not asked about.
    testWidgets('a second question retargets the one overlay', (tester) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();

      container.read(workOrderFormProvider.notifier).applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: <String, Object?>{},
        RecordWorkOrderFieldsTool.askedKey: {
          'field': 'fault_code',
          'question': 'Which code was on the panel?',
          'options': ['E-102', 'E-204'],
        },
      });
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);
      // The visible question is the pending one, not the one the route opened on.
      expect(
        tester.widget<Text>(find.byKey(ClarificationKeys.question)).data,
        'Which code was on the panel?',
      );
      expect(find.text('E-102'), findsOneWidget);
      expect(find.text('12-inch mesh'), findsNothing);

      // And the tap lands in the field the visible question named.
      await tester.tap(find.byKey(ClarificationKeys.option(0)));
      await tester.pumpAndSettle();

      final state = container.read(workOrderFormProvider);
      expect(state.textOf(WorkOrderField.faultCode), 'E-102');
      expect(state.textOf(WorkOrderField.requiredParts), '');
      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
    });

    // **What mutation M19 actually established, after the fix it seemed to call
    // for was measured and reverted.** The row expected the state check in
    // `_present`'s tail to be load-bearing; it survived. The story that fit — a
    // question arriving while the route animates out and being dismissed by its
    // close — turned out to be unreachable: an instrumented trace showed
    // `showDialog`'s future resolving in the *same frame* as the pop, with
    // `choice: null` and nothing pending, while the route was still painting its
    // exit. So what this asserts is the property that *is* real and was untested:
    // a question asked straight after an outside answer opens on its own.
    testWidgets('a question asked right after an outside answer still opens', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      final form = container.read(workOrderFormProvider.notifier);
      ask(container);
      await tester.pumpAndSettle();

      // Answered from outside the dialog — the host pops with no result.
      form.answerClarification('12-inch mesh');
      await tester.pump();

      // And the agent's next turn asks something else.
      form.applyPayload(const {
        RecordWorkOrderFieldsTool.recordedKey: <String, Object?>{},
        RecordWorkOrderFieldsTool.askedKey: {
          'field': 'fault_code',
          'question': 'Which code was on the panel?',
          'options': ['E-102', 'E-204'],
        },
      });
      await tester.pumpAndSettle();

      expect(
        container.read(workOrderFormProvider).clarification,
        isNotNull,
        reason: 'the close of the previous dialog must not clear it',
      );
      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(ClarificationKeys.question)).data,
        'Which code was on the panel?',
      );
      // And the first answer still landed.
      expect(
        container
            .read(workOrderFormProvider)
            .textOf(WorkOrderField.requiredParts),
        '12-inch mesh',
      );
    });

    // **Review finding R0-F2, and the failure it describes is not subtle: the app's
    // home route disappears.** `_showing` is assigned in the listener and the route
    // is pushed one post-frame callback later; clearing the clarification inside
    // that window used to take the `next == null` branch, find `_showing` non-null
    // and pop the *root* navigator with no dialog on the stack. No `pumpAndSettle`
    // between the two calls, deliberately — that is the whole window, and the
    // existing 'clearing the request under an open overlay pops it' test pumps one
    // and therefore cannot see this.
    testWidgets('a question cleared before its route is pushed pops nothing', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      final form = container.read(workOrderFormProvider.notifier);

      ask(container);
      form.reset();
      await tester.pumpAndSettle();

      expect(
        find.text('behind'),
        findsOneWidget,
        reason: 'the pop took the app\'s home route with it',
      );
      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      expect(container.read(workOrderFormProvider).clarification, isNull);
    });

    // And the cancelled presentation must not fire late: the post-frame callback
    // is already scheduled when the request is cleared, so `_present` has to find
    // `_showing` null and return rather than opening a dialog for a question that
    // no longer exists.
    testWidgets('the cancelled presentation does not open later', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      final form = container.read(workOrderFormProvider.notifier);

      ask(container);
      form.reset();
      await tester.pumpAndSettle();
      // A second question afterwards still works — the cancel released the slot
      // rather than wedging it.
      ask(container);
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsOneWidget);
    });

    // **Review finding R1-F2, and it is R0-F2's fix creating a new state one over.**
    // Cancelling cleared `_showing` without unscheduling the callback queued for
    // it, so a question arriving in the same frame scheduled a second one and both
    // pushed a route. No `pumpAndSettle` between the three calls — that is the
    // window, and it is the same one the R0-F2 test insists on.
    testWidgets('a question arriving in the cancel window opens one dialog', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      final form = container.read(workOrderFormProvider.notifier);

      ask(container);
      form.reset();
      ask(container);
      await tester.pumpAndSettle();

      expect(
        find.byKey(ClarificationKeys.dialog),
        findsOneWidget,
        reason: 'two scheduled presentations both pushed a route',
      );
    });

    // And the failure that made the double push more than cosmetic: answering the
    // top dialog left the other on screen over a state with no question, rendering
    // a disposed notifier, with no listener edge able to close it.
    testWidgets('answering leaves nothing stranded behind it', (tester) async {
      final container = await pumpHost(tester);
      final form = container.read(workOrderFormProvider.notifier);

      ask(container);
      form.reset();
      ask(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ClarificationKeys.option(0)));
      await tester.pumpAndSettle();

      expect(find.byKey(ClarificationKeys.dialog), findsNothing);
      expect(find.text('behind'), findsOneWidget);
      final state = container.read(workOrderFormProvider);
      expect(state.clarification, isNull);
      expect(state.textOf(WorkOrderField.requiredParts), '12-inch mesh');
    });

    // The ordinary path through the same code: answering *with the button* pops
    // with a choice, so the tail never reaches the dismissal branch at all.
    testWidgets('answering with the button does not dismiss anything', (
      tester,
    ) async {
      final container = await pumpHost(tester);
      ask(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ClarificationKeys.option(0)));
      await tester.pumpAndSettle();

      expect(
        container
            .read(workOrderFormProvider)
            .textOf(WorkOrderField.requiredParts),
        '12-inch mesh',
      );
      expect(container.read(workOrderFormProvider).clarification, isNull);
    });
  });
}
