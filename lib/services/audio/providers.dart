/// Dependency-injection seam for voice input.
///
/// Mirrors `services/inference/providers.dart`, deliberately and closely, because
/// it is solving the same problem one capability along: a real backend that needs
/// verified weights on disk, a host suite that cannot load them, and a demo where
/// the difference between "it worked" and "it looked like it worked" is invisible
/// on a screen recording.
///
/// **The Tier 0 seam is not the one to wire, and that is the whole point of this
/// file.** `engines/providers.dart`'s `sttEngineProvider` binds `FakeSttEngine` and
/// still does. Task 2.2's row states the hazard exactly: *"Pointing a microphone at
/// that Tier 0 seam yields a demo that transcribes from a script — voice input that
/// looks like it works on a device where the recogniser never ran."* So the screen
/// resolves [dictationEngineProvider], which answers the **real** engine or `null`,
/// on precisely the argument `agentEngineProvider` makes for refusing to fall back
/// to `FakeLlmEngine`. A scripted transcript is a worse failure than a scripted
/// answer, not a lesser one: it fakes the *question*, so everything downstream —
/// retrieval, the prompt, the tool call, the form — is genuine work done on words
/// nobody said.
///
/// `sttEngineProvider` keeps the fake because every existing host test resolves it
/// and none of them can load 43MB of ONNX graphs. It is the Tier 0 seam; this is
/// the device one.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../engines/impl/sherpa_stt_engine.dart';
import '../../engines/stt_engine.dart';
import '../models/model_descriptor.dart';
import '../models/model_storage.dart';
import '../models/providers.dart';
import '../retry_policy.dart';
import 'mic_capture.dart';
import 'stt_config.dart';

/// The STT model this build provisions, as a catalog entry.
///
/// A provider rather than `ModelCatalog.byId` for [modelDescriptorProvider]'s
/// stated reason: resolved through the graph, so a test overriding the provisioned
/// list overrides this with it.
final sttDescriptorProvider = Provider<ModelDescriptor?>(
  (ref) => ref.watch(modelDescriptorProvider(ModelCatalog.sttZipformerId)),
);

/// The recogniser configuration for the installed STT set, or `null` when there is
/// nothing safe to load.
///
/// `null` is a first-class answer and the condition is [ModelInstallStatus.ready]
/// and nothing weaker, which is `inferenceConfigProvider`'s rule and its reasoning:
/// `unverified` means four files are at the right paths and nothing has hashed
/// them. A recogniser built from a truncated encoder does not fail cleanly — it
/// transcribes noise, which reaches the technician as a sentence.
final sttConfigProvider = FutureProvider<SttConfig?>(retry: noRetry, (
  ref,
) async {
  final descriptor = ref.watch(sttDescriptorProvider);
  if (descriptor == null) return null;
  final status = await ref.watch(
    modelInstallStatusProvider(descriptor.id).future,
  );
  if (status != ModelInstallStatus.ready) return null;

  final storage = await ref.watch(modelStorageProvider.future);
  // The install *directory*, because Task 2.0 provisions this model as a file set
  // and `SttConfig.forInstallDirectory` composes the four paths from the names the
  // catalog installs them under. `stt_config_test.dart` asserts those names agree
  // with the catalog's, so the two halves cannot drift apart silently.
  return SttConfig.forInstallDirectory(
    storage.installDir(descriptor).path,
  ).copyWith(primer: await _loadPrimer());
});

/// Asset path of the speech the recogniser is warmed with.
@visibleForTesting
const sttPrimerAsset = 'assets/audio/stt_primer.pcm';

/// Reads [sttPrimerAsset], or answers `null` if it cannot be read.
///
/// **Null rather than a throw**, and this is the one judgement in the function:
/// the primer is a workaround for a first-word weakness, so a build that cannot
/// load it should dictate slightly worse — not refuse to dictate. Throwing here
/// would turn a missing 32KB asset into "no speech input on this device", which
/// is a much larger failure than the one being worked around.
///
/// `Uint8List.sublistView` and not `.buffer.asUint8List()`: `rootBundle.load`
/// answers a `ByteData` that may be a window onto a larger buffer, and `.buffer`
/// discards the offset and length to hand back the whole thing. That is the same
/// mistake, in the other direction, as the `Int16List` view that crashed dictation
/// on a frame at an odd offset.
Future<Uint8List?> _loadPrimer() async {
  try {
    return Uint8List.sublistView(await rootBundle.load(sttPrimerAsset));
  } on Object {
    return null;
  }
}

/// The on-device recogniser, or `null` when this device has no verified weights.
///
/// Returned **uninitialised**, exactly as `deviceLlmEngineProvider` is: building
/// the recogniser is three ONNX graphs and 359–530ms of blocking FFI (Task 2.2
/// measured it), so it happens on a deliberate action rather than because
/// something read a provider. `DictationController.start` is that action.
///
/// Disposal is wired here because forgetting it leaks a whole isolate holding the
/// graphs — the same leak `deviceLlmEngineProvider` guards against, at 43MB
/// instead of 2.6GB.
final deviceSttEngineProvider = FutureProvider<SherpaSttEngine?>(
  retry: noRetry,
  (ref) async {
    final config = await ref.watch(sttConfigProvider.future);
    if (config == null) return null;

    final engine = SherpaSttEngine(config: config);
    ref.onDispose(engine.dispose);
    return engine;
  },
);

/// The `SttEngine` the demo screen dictates through: the device recogniser, or
/// `null`.
///
/// **It never falls back to `FakeSttEngine`** — see the library doc. Interface-typed
/// rather than `SherpaSttEngine`-typed for `agentEngineProvider`'s reason: a
/// concrete return type is a provider a test cannot substitute into.
final dictationEngineProvider = FutureProvider<SttEngine?>(
  retry: noRetry,
  (ref) => ref.watch(deviceSttEngineProvider.future),
);

/// The microphone.
///
/// One instance for the app, because [MicCapture] is what serialises access to a
/// single piece of hardware: it answers `MicCaptureBusy` for an overlapping start
/// and waits out a previous session's release, and a second instance would make
/// both of those guarantees vacuous — `record` 7.1.1 silently closes the first
/// stream when a second `startStream` arrives, so the failure would be a transcript
/// that stops mid-sentence with nothing to point at.
///
/// Left at its defaults: 16 kHz mono (what `SttConfig` declares and what the
/// recogniser is built at), a two-second backlog, and the five-second stall
/// watchdog that Task 2.1's R0-F1/R0-F2 established is the only "the microphone
/// went away" condition either platform actually produces.
final micCaptureProvider = Provider<MicCapture>((ref) {
  final capture = MicCapture(input: RecordAudioInput());
  ref.onDispose(capture.dispose);
  return capture;
});
