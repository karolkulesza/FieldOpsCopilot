import 'package:field_ops_copilot/models/form_state_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorkOrderField.byKey', () {
    test('resolves every field by its own wire name', () {
      for (final field in WorkOrderField.values) {
        expect(WorkOrderField.byKey(field.wireName), field);
      }
    });

    // The property `ToolCallGuard` uses, restated as a test rather than as a
    // comment: these spellings are not enumerated anywhere in the production code.
    test('resolves a near-miss spelling by normalisation, not by a list', () {
      for (final spelling in const [
        'faultCode',
        'Fault Code',
        'fault-code',
        'FAULT_CODE',
        '  fault code  ',
        'fault.code',
      ]) {
        expect(WorkOrderField.byKey(spelling), WorkOrderField.faultCode);
      }
    });

    test('refuses a key that names no field', () {
      expect(WorkOrderField.byKey('elevator_colour'), isNull);
      expect(WorkOrderField.byKey(''), isNull);
      // Normalises to empty, which must not match a field whose wire name also
      // normalises to something — the `key.isEmpty` early return.
      expect(WorkOrderField.byKey('---'), isNull);
    });

    // The claim `byKey`'s doc makes, bound. A fifth field colliding under
    // normalisation would make resolution ambiguous, and `byKey` returns the first
    // match rather than refusing — so the *absence* of a collision is what makes it
    // correct, and that has to be checked rather than asserted in prose.
    test('the four wire names are distinct under normalisation', () {
      final normalised = WorkOrderField.values
          .map((f) => WorkOrderField.normalizeKey(f.wireName))
          .toSet();
      expect(normalised, hasLength(WorkOrderField.values.length));
    });

    // The wire names reach the model and are snapshotted, so a duplicate would make
    // two different refusals indistinguishable in a transcript.
    test('every rejection reason has a distinct wire name', () {
      expect(
        FormUpdateRejection.values.map((r) => r.wireName).toSet(),
        hasLength(FormUpdateRejection.values.length),
      );
    });

    test('every field carries a non-empty label and hint', () {
      for (final field in WorkOrderField.values) {
        expect(field.label.trim(), isNotEmpty, reason: field.name);
        expect(field.hint.trim(), isNotEmpty, reason: field.name);
      }
    });
  });

  group('parseFormUpdates', () {
    test('accepts the AC payload', () {
      final parse = parseFormUpdates(const {
        'fault_code': 'E-102',
        'required_parts': 'BRK-990-XP',
      });

      expect(parse.accepted, {
        WorkOrderField.faultCode: 'E-102',
        WorkOrderField.requiredParts: 'BRK-990-XP',
      });
      expect(parse.rejected, isEmpty);
      expect(parse.isEmpty, isFalse);
    });

    test('trims accepted values', () {
      final parse = parseFormUpdates(const {'fault_code': '  E-102 \n'});
      expect(parse.accepted[WorkOrderField.faultCode], 'E-102');
    });

    test('an empty map yields nothing accepted and nothing rejected', () {
      final parse = parseFormUpdates(const <String, Object?>{});
      expect(parse.accepted, isEmpty);
      expect(parse.rejected, isEmpty);
      expect(parse.isEmpty, isTrue);
    });

    test('an unknown key is rejected, and the rest still apply', () {
      final parse = parseFormUpdates(const {
        'fault_code': 'E-102',
        'elevator_colour': 'green',
      });

      expect(parse.accepted, {WorkOrderField.faultCode: 'E-102'});
      expect(parse.rejected, hasLength(1));
      expect(parse.rejected.single.key, 'elevator_colour');
      expect(parse.rejected.single.reason, FormUpdateRejection.unknownField);
      // The message has to tell the model what the fields *are*, or it has nothing
      // to correct towards.
      for (final field in WorkOrderField.values) {
        expect(parse.rejected.single.message, contains(field.wireName));
      }
    });

    // The decision in the library doc: refused, not `2.toString()`.
    test('a non-string value is refused rather than coerced', () {
      final parse = parseFormUpdates(const {
        'technician_hours': 2,
        'safety_checkpoints': ['lockout'],
        'fault_code': true,
      });

      expect(parse.accepted, isEmpty);
      expect(
        parse.rejected.map((r) => r.reason),
        everyElement(FormUpdateRejection.notAString),
      );
      expect(parse.rejected.map((r) => r.key), [
        'technician_hours',
        'safety_checkpoints',
        'fault_code',
      ]);
    });

    test('a blank string is its own rejection, not "not a string"', () {
      final parse = parseFormUpdates(const {
        'fault_code': '',
        'required_parts': '   ',
      });

      expect(parse.accepted, isEmpty);
      expect(
        parse.rejected.map((r) => r.reason),
        everyElement(FormUpdateRejection.blank),
      );
    });

    test('a null value is refused as not-a-string', () {
      final parse = parseFormUpdates(const {'fault_code': null});
      expect(parse.rejected.single.reason, FormUpdateRejection.notAString);
    });

    test('a rejected key is quoted as the model spelled it', () {
      final parse = parseFormUpdates(const {'FaultCodeX': 'E-102'});
      expect(parse.rejected.single.key, 'FaultCodeX');
    });

    // Documented behaviour rather than an accident: `Map` from the wire is
    // `Map<Object?, Object?>`, so a non-string key is possible and must be named in
    // its own rejection rather than crashing the parse.
    test('a non-string key is named in its rejection', () {
      final parse = parseFormUpdates(<Object?, Object?>{7: 'E-102'});
      expect(parse.rejected.single.key, '7');
      expect(parse.rejected.single.reason, FormUpdateRejection.unknownField);
    });

    test('two keys that canonicalise alike: the last one wins', () {
      final parse = parseFormUpdates(const {
        'fault_code': 'E-102',
        'faultCode': 'E-204',
      });
      expect(parse.accepted, {WorkOrderField.faultCode: 'E-204'});
    });
  });

  group('parseClarification', () {
    ClarificationRequest parsed(Object? raw) {
      final parse = parseClarification(raw);
      expect(parse.rejection, isNull, reason: '$raw');
      return parse.request!;
    }

    test('reads the AC payload', () {
      final request = parsed(const {
        'field': 'required_parts',
        'question': 'Which filter did you use?',
        'options': ['12-inch mesh', '14-inch carbon'],
      });

      expect(request.field, WorkOrderField.requiredParts);
      expect(request.question, 'Which filter did you use?');
      expect(request.options, ['12-inch mesh', '14-inch carbon']);
    });

    test('absent is neither a request nor a rejection', () {
      final parse = parseClarification(null);
      expect(parse.request, isNull);
      expect(parse.rejection, isNull);
    });

    test('fewer than two usable options is refused', () {
      for (final options in const [
        <Object?>[],
        <Object?>['only one'],
        <Object?>['same', 'same'],
        <Object?>['kept', '  ', null, 7],
      ]) {
        final parse = parseClarification({
          'field': 'required_parts',
          'question': 'Which?',
          'options': options,
        });
        expect(parse.request, isNull, reason: '$options');
        expect(parse.rejection, isNotNull, reason: '$options');
      }
    });

    test('unusable entries are dropped while two real ones survive', () {
      final request = parsed(const {
        'field': 'required_parts',
        'question': 'Which?',
        'options': ['12-inch mesh', null, 7, '  ', '14-inch carbon'],
      });
      expect(request.options, ['12-inch mesh', '14-inch carbon']);
    });

    test('duplicate options are collapsed, keeping the first spelling', () {
      final request = parsed(const {
        'field': 'required_parts',
        'question': 'Which?',
        'options': ['12-inch mesh', ' 12-inch mesh ', '14-inch carbon'],
      });
      expect(request.options, ['12-inch mesh', '14-inch carbon']);
    });

    test('a field that names nothing is refused', () {
      final parse = parseClarification(const {
        'field': 'elevator_colour',
        'question': 'Which?',
        'options': ['a', 'b'],
      });
      expect(parse.rejection, isNotNull);
      expect(parse.rejection!.key, clarificationArgument);
      expect(
        parse.rejection!.reason,
        FormUpdateRejection.unusableClarification,
      );
    });

    // Every clarification refusal is one reason, which is the decision on the enum
    // value. Held here so that splitting it into four is a visible edit.
    test('every clarification refusal carries the one reason', () {
      for (final raw in const <Object?>[
        'not an object',
        {
          'field': 'nope',
          'question': 'Which?',
          'options': ['a', 'b'],
        },
        {
          'field': 'fault_code',
          'question': '',
          'options': ['a', 'b'],
        },
        {'field': 'fault_code', 'question': 'Which?', 'options': 'a or b'},
        {
          'field': 'fault_code',
          'question': 'Which?',
          'options': ['only'],
        },
      ]) {
        final parse = parseClarification(raw);
        expect(
          parse.rejection?.reason,
          FormUpdateRejection.unusableClarification,
          reason: '$raw',
        );
      }
    });

    test('a blank or missing question is refused', () {
      for (final question in const <Object?>[null, '', '   ', 7]) {
        final parse = parseClarification({
          'field': 'required_parts',
          'question': question,
          'options': ['a', 'b'],
        });
        expect(parse.rejection, isNotNull, reason: '$question');
      }
    });

    test('a non-map, and options that are not a list, are refused', () {
      expect(parseClarification('which one?').rejection, isNotNull);
      expect(
        parseClarification(const {
          'field': 'required_parts',
          'question': 'Which?',
          'options': 'a or b',
        }).rejection,
        isNotNull,
      );
    });

    test('the parsed option list cannot be mutated by a caller', () {
      final request = parsed(const {
        'field': 'required_parts',
        'question': 'Which?',
        'options': ['a', 'b'],
      });
      expect(() => request.options.add('c'), throwsUnsupportedError);
    });

    test('two requests with the same content are equal', () {
      const raw = {
        'field': 'required_parts',
        'question': 'Which?',
        'options': ['a', 'b'],
      };
      expect(parsed(raw), parsed(raw));
      expect(parsed(raw).hashCode, parsed(raw).hashCode);
    });
  });

  group('WorkOrderFormState', () {
    const empty = WorkOrderFormState();

    test('starts empty and reads an unset field as the empty string', () {
      expect(empty.isEmpty, isTrue);
      expect(empty.textOf(WorkOrderField.faultCode), '');
      expect(empty.clarification, isNull);
    });

    test('applies agent updates and records their origin', () {
      final state = empty.applyUpdates(
        parseFormUpdates(const {'fault_code': 'E-102'}),
      );

      expect(state.textOf(WorkOrderField.faultCode), 'E-102');
      expect(
        state.fields[WorkOrderField.faultCode]!.origin,
        FormFieldOrigin.agent,
      );
      expect(state.isEmpty, isFalse);
    });

    test('an agent update overwrites an earlier agent value outright', () {
      final state = empty
          .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}))
          .applyUpdates(parseFormUpdates(const {'fault_code': 'E-204'}));

      expect(state.textOf(WorkOrderField.faultCode), 'E-204');
      expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
    });

    test('rejections accumulate across runs', () {
      final state = empty
          .applyUpdates(parseFormUpdates(const {'nope': 'x'}))
          .applyUpdates(parseFormUpdates(const {'also_nope': 'y'}));

      expect(state.rejected.map((r) => r.key), ['nope', 'also_nope']);
    });

    group('the technician outranks the agent', () {
      final typed = empty.withTechnicianEntry(
        WorkOrderField.faultCode,
        'E-999',
      );

      test('a conflicting agent update is parked, not applied', () {
        final state = typed.applyUpdates(
          parseFormUpdates(const {'fault_code': 'E-102'}),
        );

        expect(state.textOf(WorkOrderField.faultCode), 'E-999');
        expect(state.fields[WorkOrderField.faultCode]!.suggestion, 'E-102');
        expect(
          state.fields[WorkOrderField.faultCode]!.origin,
          FormFieldOrigin.technician,
        );
      });

      test('an agreeing agent update raises no suggestion', () {
        final state = typed.applyUpdates(
          parseFormUpdates(const {'fault_code': 'E-999'}),
        );

        expect(state.textOf(WorkOrderField.faultCode), 'E-999');
        expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
      });

      test('an agreeing update clears a suggestion the last one raised', () {
        final state = typed
            .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}))
            .applyUpdates(parseFormUpdates(const {'fault_code': 'E-999'}));

        expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
      });

      test('accepting the suggestion installs it and keeps human origin', () {
        final state = typed
            .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}))
            .acceptSuggestion(WorkOrderField.faultCode);

        expect(state.textOf(WorkOrderField.faultCode), 'E-102');
        expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
        expect(
          state.fields[WorkOrderField.faultCode]!.origin,
          FormFieldOrigin.technician,
          reason:
              'the technician accepted it, so the next agent update is still '
              'parked rather than applied',
        );
      });

      test('dismissing the suggestion keeps what is in the field', () {
        final state = typed
            .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}))
            .dismissSuggestion(WorkOrderField.faultCode);

        expect(state.textOf(WorkOrderField.faultCode), 'E-999');
        expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
      });

      test('accepting or dismissing nothing is a no-op, not a throw', () {
        expect(empty.acceptSuggestion(WorkOrderField.faultCode), same(empty));
        expect(empty.dismissSuggestion(WorkOrderField.faultCode), same(empty));
        expect(
          typed.acceptSuggestion(WorkOrderField.faultCode).fields,
          typed.fields,
        );
      });

      test('typing over a field drops its pending suggestion', () {
        final state = typed
            .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}))
            .withTechnicianEntry(WorkOrderField.faultCode, 'E-777');

        expect(state.textOf(WorkOrderField.faultCode), 'E-777');
        expect(state.fields[WorkOrderField.faultCode]!.hasSuggestion, isFalse);
      });
    });

    test('a technician clearing a field removes it', () {
      final state = empty
          .withTechnicianEntry(WorkOrderField.faultCode, 'E-999')
          .withTechnicianEntry(WorkOrderField.faultCode, '  ');

      expect(state.fields, isEmpty);
      expect(state.textOf(WorkOrderField.faultCode), '');
    });

    // The asymmetry the library doc argues for, held in one place so that
    // deleting either half fails here.
    test('blank erases from the technician and never from the agent', () {
      final typed = empty.withTechnicianEntry(
        WorkOrderField.faultCode,
        'E-999',
      );

      expect(
        typed
            .applyUpdates(parseFormUpdates(const {'fault_code': ''}))
            .textOf(WorkOrderField.faultCode),
        'E-999',
      );
      expect(
        typed
            .withTechnicianEntry(WorkOrderField.faultCode, '')
            .textOf(WorkOrderField.faultCode),
        '',
      );
    });

    group('clarification', () {
      const request = ClarificationRequest(
        field: WorkOrderField.requiredParts,
        question: 'Which filter did you use?',
        options: ['12-inch mesh', '14-inch carbon'],
      );

      test('answering fills the field and closes the question', () {
        final state = empty
            .withClarification(request)
            .answerClarification('14-inch carbon');

        expect(state.textOf(WorkOrderField.requiredParts), '14-inch carbon');
        expect(
          state.fields[WorkOrderField.requiredParts]!.origin,
          FormFieldOrigin.clarification,
        );
        expect(state.clarification, isNull);
      });

      test('an answer overrules even a technician entry', () {
        final state = empty
            .withTechnicianEntry(WorkOrderField.requiredParts, 'something else')
            .withClarification(request)
            .answerClarification('12-inch mesh');

        expect(state.textOf(WorkOrderField.requiredParts), '12-inch mesh');
      });

      test('answering with nothing pending is a no-op', () {
        expect(empty.answerClarification('12-inch mesh'), same(empty));
      });

      test('a blank answer neither fills nor closes', () {
        final asking = empty.withClarification(request);
        final state = asking.answerClarification('   ');

        expect(state.fields, isEmpty);
        expect(state.clarification, request);
      });

      test('dismissing closes it without filling anything', () {
        final state = empty.withClarification(request).withoutClarification();

        expect(state.clarification, isNull);
        expect(state.fields, isEmpty);
      });

      test('a second question replaces the first', () {
        const second = ClarificationRequest(
          field: WorkOrderField.faultCode,
          question: 'Which code was on the panel?',
          options: ['E-102', 'E-204'],
        );

        final state = empty
            .withClarification(request)
            .withClarification(second);

        expect(state.clarification, second);
      });
    });
  });

  // **The device produced a work order that mixed two jobs, and this is the
  // group that stops it.** A brake fault recorded four fields; a door fault
  // diagnosed next on the same screen overwrote the two it had values for and
  // left `technician_hours: 1.5` and `safety_checkpoints: lockout/tagout
  // verified` behind — still marked as the agent's, so the panel asserted the
  // model had recorded them for the door fault. Every value was one the agent
  // really had produced, which is exactly what made it convincing.
  group('WorkOrderFormState.forNewInquiry', () {
    const empty = WorkOrderFormState();

    test("drops the agent's fields", () {
      final state = empty.applyUpdates(
        parseFormUpdates(const {
          'fault_code': 'E-102',
          'technician_hours': '1.5',
        }),
      );
      expect(state.fields, hasLength(2));

      final next = state.forNewInquiry();

      expect(next.fields, isEmpty);
      expect(next.isEmpty, isTrue);
    });

    test('keeps what the technician typed', () {
      final state = empty
          .withTechnicianEntry(WorkOrderField.faultCode, 'E-999')
          .applyUpdates(parseFormUpdates(const {'technician_hours': '1.5'}));

      final next = state.forNewInquiry();

      expect(next.textOf(WorkOrderField.faultCode), 'E-999');
      expect(
        next.fields[WorkOrderField.faultCode]!.origin,
        FormFieldOrigin.technician,
        reason:
            'a surviving field must stay theirs — demoted to the agent it '
            'would be silently overwritten by the next inquiry',
      );
      expect(next.textOf(WorkOrderField.technicianHours), '');
    });

    test('drops a suggestion parked against a surviving field', () {
      // The same defect one indirection deeper: a suggestion is the agent's
      // reading of the *previous* inquiry, and carrying it forward offers stale
      // text against the new one as though it were live.
      final state = empty
          .withTechnicianEntry(WorkOrderField.faultCode, 'E-999')
          .applyUpdates(parseFormUpdates(const {'fault_code': 'E-102'}));
      expect(state.fields[WorkOrderField.faultCode]!.suggestion, 'E-102');

      final next = state.forNewInquiry();

      expect(next.textOf(WorkOrderField.faultCode), 'E-999');
      expect(next.fields[WorkOrderField.faultCode]!.suggestion, isNull);
    });

    test('clears refusals and any pending question', () {
      // The panel's line reads "the assistant sent N values this form has no
      // fields for" — a sentence about the run being reported, not about every
      // run since launch. A question from the previous inquiry is stale for the
      // same reason, and `rejected` is the one that had a test proving it
      // *accumulates* across runs, which is right within an inquiry and wrong
      // across two.
      final state = empty
          .applyUpdates(parseFormUpdates(const {'nope': 'x'}))
          .withClarification(
            const ClarificationRequest(
              field: WorkOrderField.faultCode,
              question: 'Which one?',
              options: ['E-102', 'E-305'],
            ),
          );
      expect(state.rejected, isNotEmpty);

      final next = state.forNewInquiry();

      expect(next.rejected, isEmpty);
      expect(next.clarification, isNull);
    });
  });
}
