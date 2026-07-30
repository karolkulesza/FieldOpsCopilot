import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../engines/llm_engine.dart';
import '../engines/providers.dart';
import 'components/model_readiness_banner.dart';

/// Skeleton home screen.
///
/// Exercises the [LlmEngine] streaming contract end-to-end against the injected
/// (fake) engine: it initialises the engine, streams a scripted response
/// token-by-token, and renders the accumulating text. This is the walking
/// skeleton the rest of the vertical slice grows into.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _output = '';
  bool _ready = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    final engine = ref.read(llmEngineProvider);
    await engine.initialize();
    if (mounted) setState(() => _ready = engine.isReady);
  }

  Future<void> _runDemo() async {
    final engine = ref.read(llmEngineProvider);
    setState(() {
      _running = true;
      _output = '';
    });
    await for (final event in engine.generate(prompt: 'diagnostic self-test')) {
      if (event is LlmToken && mounted) {
        setState(() => _output += event.text);
      }
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('FieldOps Copilot'),
        backgroundColor: theme.colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _ready ? Icons.check_circle : Icons.hourglass_empty,
                  color: _ready
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
                ),
                const SizedBox(width: 8),
                Text(
                  _ready ? 'Engine ready (fake)' : 'Initialising engine…',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Whether verified weights are on the device, which is a separate
            // question from whether the engine seam is wired: today the engine
            // above is the fake, and it is ready regardless.
            const ModelReadinessBanner(),
            const SizedBox(height: 24),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _output.isEmpty
                        ? 'Tap “Run self-test” to stream a response.'
                        : _output,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _ready && !_running ? _runDemo : null,
              icon: const Icon(Icons.play_arrow),
              label: Text(_running ? 'Streaming…' : 'Run self-test'),
            ),
          ],
        ),
      ),
    );
  }
}
