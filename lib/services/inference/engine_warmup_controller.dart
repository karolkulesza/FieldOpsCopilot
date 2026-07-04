/// Loads the model weights before the UI needs to be interactive.
///
/// Task 1.8 shipped [deviceLlmEngineProvider] returning an engine that has *not*
/// been initialised, deliberately: loading is seconds of work and gigabytes of
/// memory, so it should be a decision rather than a side effect of reading a
/// provider. This is the decision, and Task 1.11's brief is explicit about when it
/// has to happen — "load the weights before the UI needs to be interactive, behind
/// the readiness banner … design for it rather than discover it".
///
/// **The measurement that shapes this file.** On the demo device (iPad Air M4,
/// iOS 26.5, Metal) Task 1.8 measured the *UI isolate* stalling **1445–1728ms**
/// during the load, across two runs — roughly 90 dropped frames at a 16.7ms
/// budget. The inference isolate is real and the app owns it; the stall is not the
/// inference, it is the load. Cause unsettled (Task 1.8-F): Metal pipeline
/// compilation is eliminated by a forced-CPU run that stalled *worse* while
/// loading faster, and the live hypotheses are memory traffic during the `mmap`
/// walk and a major GC pause from the worker's shared isolate group.
///
/// Two consequences are designed for here rather than discovered:
///
/// 1. **The load starts at app start**, not when someone taps Diagnose. The demo
///    screen is the app's home, so mounting it is the earliest honest moment; by
///    the time a technician has typed an inquiry the weights are resident. What is
///    *not* acceptable is a stall between the tap and the first token, because
///    that is the moment being recorded.
/// 2. **Nothing animates while it happens.** This is the trap in the obvious
///    implementation, and it is worth stating because a spinner is the reflex:
///    what stalls is the UI isolate, so a progress indicator displayed *during*
///    the load freezes with it, and a frozen indicator reads as a crash. So
///    [EngineLoading] is rendered as a static row — see `diagnose_screen.dart`,
///    where a test asserts no `ProgressIndicator` is in that subtree.
///
/// The state below is set to [EngineLoading] *before* the load is awaited, so the
/// frame showing the static row is scheduled and painted on the other side of an
/// await boundary — i.e. before the isolate work that stalls the UI thread begins.
/// Ordering the two the other way would mean the stall happens while the screen
/// still shows the previous state, which is the same defect wearing different
/// clothes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engines/llm_engine.dart';
import 'providers.dart';

/// Where the on-device engine is in its lifecycle.
@immutable
sealed class EngineWarmupState {
  const EngineWarmupState();
}

/// Nothing has been attempted yet.
final class EngineIdle extends EngineWarmupState {
  const EngineIdle();
}

/// Weights are being loaded. **Render this without animation** — see the library
/// doc; the UI isolate stalls for 1445–1728ms inside it on the demo device.
final class EngineLoading extends EngineWarmupState {
  const EngineLoading();
}

/// The engine is loaded and will accept `generate`.
final class EngineReady extends EngineWarmupState {
  const EngineReady(this.engine);

  /// Carried on the state rather than re-read from a provider, so a caller that
  /// has an [EngineReady] cannot then be handed a different or disposed engine.
  final LlmEngine engine;
}

/// This device has no verified weights, so there is nothing to load.
///
/// Distinct from [EngineFailed] because the operator's next step is completely
/// different and already on screen: `ModelReadinessBanner` says which of "not
/// installed", "needs verification" or "source not configured" applies, and offers
/// the action. Reporting that as an *error* would put a second, vaguer message
/// above the specific one.
final class EngineUnavailable extends EngineWarmupState {
  const EngineUnavailable();
}

/// Loading was attempted and threw.
final class EngineFailed extends EngineWarmupState {
  const EngineFailed(this.message);

  final String message;
}

/// Drives `LlmEngine.initialize()` on behalf of the UI.
///
/// Mirrors `ModelProvisioningController`, which drives the download the same way
/// and for the same reason: the work is slow, it can fail, and the UI needs to
/// name which of those is happening.
class EngineWarmupController extends Notifier<EngineWarmupState> {
  @override
  EngineWarmupState build() => const EngineIdle();

  /// Loads the weights, unless a load is already running or finished.
  ///
  /// Idempotent, because the caller is a widget's `initState` and widgets are
  /// rebuilt: a second call while [EngineLoading] or after [EngineReady] does
  /// nothing. A second call after [EngineFailed] or [EngineUnavailable] *does*
  /// retry, which is the one case where trying again can differ — the operator may
  /// have provisioned the weights in between, and
  /// `ModelProvisioningController.provision` invalidates
  /// `modelInstallStatusProvider` when it succeeds, so the engine this reads is a
  /// new one.
  Future<void> warmUp() async {
    if (state is EngineLoading || state is EngineReady) return;

    // Set before anything is awaited, so the static "loading" row is painted
    // before the load that stalls the UI isolate begins. See the library doc.
    state = const EngineLoading();

    final LlmEngine? engine;
    try {
      engine = await ref.read(agentEngineProvider.future);
    } on Exception catch (error) {
      // `on Exception`, not `on Object`, for the reason `ToolRegistry.dispatch`
      // gives: an `Error` here means the app is broken rather than the device
      // being unready, and reporting it as "the model could not load" would hide a
      // defect behind a plausible operational message.
      _fail('the model could not be prepared: $error');
      return;
    }
    if (!ref.mounted) return;

    if (engine == null) {
      state = const EngineUnavailable();
      return;
    }
    if (engine.isReady) {
      // A rebuild of this controller over an engine that survived it. Loading
      // again would spend seconds and gigabytes to reach the state it is in.
      state = EngineReady(engine);
      return;
    }

    try {
      await engine.initialize();
    } on Exception catch (error) {
      _fail('the model failed to load: $error');
      return;
    }
    if (!ref.mounted) return;

    // `isReady` is asked rather than assumed. `initialize()` returning without
    // throwing is the engine's claim; this is the interface's own answer to the
    // question the loop will ask, and `AgentLoop.run` throws a `StateError` if it
    // is false — a crash rather than a message, on the tap that is being recorded.
    state = engine.isReady
        ? EngineReady(engine)
        : const EngineFailed(
            'the model reported that it loaded but is not ready to generate',
          );
  }

  void _fail(String message) {
    if (!ref.mounted) return;
    debugPrint('[EngineWarmup] $message');
    state = EngineFailed(message);
  }
}

/// The warm-up trigger the demo screen reads.
final engineWarmupControllerProvider =
    NotifierProvider<EngineWarmupController, EngineWarmupState>(
      EngineWarmupController.new,
    );
