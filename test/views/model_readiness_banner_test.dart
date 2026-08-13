import 'package:field_ops_copilot/services/models/model_descriptor.dart';
import 'package:field_ops_copilot/services/models/model_storage.dart';
import 'package:field_ops_copilot/services/models/providers.dart';
import 'package:field_ops_copilot/views/components/model_readiness_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget coverage for the "model ready" state required by Task 1.7's demo-day
/// risk control: the operator must be able to see, before tapping anything,
/// whether verified weights are on the device.
///
/// Task 2.0 extends the banner to one row per provisioned model, so the pump
/// takes a *list* of descriptors and a status per model id — and the multi-model
/// scenarios (TC-PROV-MULTI-01's banner half) assert that the rows are
/// independent.
void main() {
  final configured = ModelDescriptor(
    id: 'gemma-test',
    displayName: 'Gemma 4 E2B (INT4, LiteRT-LM)',
    fileName: 'gemma-test.litertlm',
    licensePage: 'https://example.invalid/license',
    sha256Hex:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  /// A committed-config multi-file model shaped like the STT set: sources and
  /// pins present on the descriptor itself, no overlay involved.
  final sttLike = ModelDescriptor.fileSet(
    id: 'stt-test',
    displayName: 'Zipformer STT (test fixture)',
    licensePage: 'https://example.invalid/stt',
    files: [
      for (final name in ['encoder.onnx', 'tokens.txt'])
        ModelArtifactFile(
          fileName: name,
          downloadUri: Uri.parse('https://example.invalid/$name'),
          sha256Hex: 'b' * 64,
        ),
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<ModelDescriptor> descriptors,
    Map<String, ModelInstallStatus> statuses = const {},
    Object? error,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          provisionedModelDescriptorsProvider.overrideWithValue(descriptors),
          modelInstallStatusProvider.overrideWith((ref, modelId) async {
            if (error != null) throw error;
            return statuses[modelId]!;
          }),
        ],
        child: const MaterialApp(home: Scaffold(body: ModelReadinessBanner())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('reports a verified model as ready, naming it', (tester) async {
    await pump(
      tester,
      descriptors: [
        configured.withSource(
          downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
          sha256Hex: configured.soleFile.sha256Hex,
        ),
      ],
      statuses: {'gemma-test': ModelInstallStatus.ready},
    );

    expect(find.text('Model ready'), findsOneWidget);
    expect(find.text('Gemma 4 E2B (INT4, LiteRT-LM)'), findsOneWidget);
  });

  testWidgets('distinguishes present-but-unverified weights from ready', (
    tester,
  ) async {
    await pump(
      tester,
      descriptors: [
        configured.withSource(
          downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
          sha256Hex: configured.soleFile.sha256Hex,
        ),
      ],
      statuses: {'gemma-test': ModelInstallStatus.unverified},
    );

    expect(find.text('Model needs verification'), findsOneWidget);
    expect(find.text('Model ready'), findsNothing);
  });

  testWidgets('a configured-but-missing model prompts for the download', (
    tester,
  ) async {
    await pump(
      tester,
      descriptors: [
        configured.withSource(
          downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
          sha256Hex: configured.soleFile.sha256Hex,
        ),
      ],
      statuses: {'gemma-test': ModelInstallStatus.absent},
    );

    expect(find.text('Model not installed'), findsOneWidget);
  });

  testWidgets('a missing source URL is named as a configuration problem', (
    tester,
  ) async {
    // Same install state as above (absent), but the operator's next action is
    // completely different — that distinction is the point of this branch.
    await pump(
      tester,
      descriptors: [
        configured.withSource(
          downloadUri: null,
          sha256Hex: configured.soleFile.sha256Hex,
        ),
      ],
      statuses: {'gemma-test': ModelInstallStatus.absent},
    );

    expect(find.text('Model source not configured'), findsOneWidget);
    expect(find.textContaining('FIELDOPS_MODEL_URI'), findsOneWidget);
    expect(find.textContaining('example.invalid/license'), findsOneWidget);
  });

  testWidgets('an unpinned hash is named as a configuration problem', (
    tester,
  ) async {
    await pump(
      tester,
      descriptors: [
        configured.withSource(
          downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
          sha256Hex: '',
        ),
      ],
      statuses: {'gemma-test': ModelInstallStatus.absent},
    );

    expect(find.text('Model hash not pinned'), findsOneWidget);
    expect(find.textContaining('FIELDOPS_MODEL_SHA256'), findsOneWidget);
  });

  testWidgets('a failed status check is not rendered as ready or absent', (
    tester,
  ) async {
    await pump(
      tester,
      descriptors: [configured],
      error: StateError('application support directory unavailable'),
    );

    expect(find.text('Model status unavailable'), findsOneWidget);
    expect(find.text('Model ready'), findsNothing);
    expect(find.text('Model not installed'), findsNothing);
  });

  group('one row per provisioned model (TC-PROV-MULTI-01, banner half)', () {
    testWidgets('renders a row for every provisioned model', (tester) async {
      await pump(
        tester,
        descriptors: [
          configured.withSource(
            downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
            sha256Hex: configured.soleFile.sha256Hex,
          ),
          sttLike,
        ],
        statuses: {
          'gemma-test': ModelInstallStatus.ready,
          'stt-test': ModelInstallStatus.ready,
        },
      );

      expect(find.text('Model ready'), findsNWidgets(2));
      expect(find.text('Gemma 4 E2B (INT4, LiteRT-LM)'), findsOneWidget);
      expect(find.text('Zipformer STT (test fixture)'), findsOneWidget);
    });

    testWidgets(
      'an absent STT set renders as one missing row while the LLM row stays '
      'ready',
      (tester) async {
        await pump(
          tester,
          descriptors: [
            configured.withSource(
              downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
              sha256Hex: configured.soleFile.sha256Hex,
            ),
            sttLike,
          ],
          statuses: {
            'gemma-test': ModelInstallStatus.ready,
            'stt-test': ModelInstallStatus.absent,
          },
        );

        // Both truths on screen at once — neither masks the other.
        expect(find.text('Model ready'), findsOneWidget);
        expect(find.text('Gemma 4 E2B (INT4, LiteRT-LM)'), findsOneWidget);
        expect(find.text('Model not installed'), findsOneWidget);
        expect(find.text('Zipformer STT (test fixture)'), findsOneWidget);
        // The STT row's committed config offers its own download; the ready
        // LLM row offers nothing — one button, and it belongs to the STT row.
        expect(find.text('Download & verify weights'), findsOneWidget);
      },
    );

    testWidgets('the LLM being unconfigured does not hide the STT row', (
      tester,
    ) async {
      await pump(
        tester,
        descriptors: [
          configured.withSource(downloadUri: null, sha256Hex: ''),
          sttLike,
        ],
        statuses: {
          'gemma-test': ModelInstallStatus.absent,
          'stt-test': ModelInstallStatus.ready,
        },
      );

      expect(find.text('Model source not configured'), findsOneWidget);
      expect(find.text('Model ready'), findsOneWidget);
      expect(find.text('Zipformer STT (test fixture)'), findsOneWidget);
    });
  });
}
