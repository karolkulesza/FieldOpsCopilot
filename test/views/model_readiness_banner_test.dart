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
void main() {
  const configured = ModelDescriptor(
    id: 'gemma-test',
    displayName: 'Gemma 4 E2B (INT4, LiteRT-LM)',
    fileName: 'gemma-test.litertlm',
    licensePage: 'https://example.invalid/license',
    sha256Hex:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  );

  Future<void> pump(
    WidgetTester tester, {
    required ModelDescriptor descriptor,
    ModelInstallStatus? status,
    Object? error,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeModelDescriptorProvider.overrideWithValue(descriptor),
          modelInstallStatusProvider.overrideWith((ref) async {
            if (error != null) throw error;
            return status!;
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
      descriptor: configured.withSource(
        downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
        sha256Hex: configured.sha256Hex,
      ),
      status: ModelInstallStatus.ready,
    );

    expect(find.text('Model ready'), findsOneWidget);
    expect(find.text('Gemma 4 E2B (INT4, LiteRT-LM)'), findsOneWidget);
  });

  testWidgets('distinguishes present-but-unverified weights from ready', (
    tester,
  ) async {
    await pump(
      tester,
      descriptor: configured.withSource(
        downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
        sha256Hex: configured.sha256Hex,
      ),
      status: ModelInstallStatus.unverified,
    );

    expect(find.text('Model needs verification'), findsOneWidget);
    expect(find.text('Model ready'), findsNothing);
  });

  testWidgets('a configured-but-missing model prompts for the download', (
    tester,
  ) async {
    await pump(
      tester,
      descriptor: configured.withSource(
        downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
        sha256Hex: configured.sha256Hex,
      ),
      status: ModelInstallStatus.absent,
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
      descriptor: configured.withSource(
        downloadUri: null,
        sha256Hex: configured.sha256Hex,
      ),
      status: ModelInstallStatus.absent,
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
      descriptor: configured.withSource(
        downloadUri: Uri.parse('https://example.invalid/gemma.litertlm'),
        sha256Hex: '',
      ),
      status: ModelInstallStatus.absent,
    );

    expect(find.text('Model hash not pinned'), findsOneWidget);
    expect(find.textContaining('FIELDOPS_MODEL_SHA256'), findsOneWidget);
  });

  testWidgets('a failed status check is not rendered as ready or absent', (
    tester,
  ) async {
    await pump(
      tester,
      descriptor: configured,
      error: StateError('application support directory unavailable'),
    );

    expect(find.text('Model status unavailable'), findsOneWidget);
    expect(find.text('Model ready'), findsNothing);
    expect(find.text('Model not installed'), findsNothing);
  });
}
