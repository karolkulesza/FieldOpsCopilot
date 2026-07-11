# FieldOps Copilot

An offline-first mobile application for field-service technicians maintaining
smart elevators (the fictional **Apex-9** series). It is designed to run entirely
on-device — no cellular connectivity required — combining an on-device language
model, speech-to-text, camera-based OCR, and a local full-text-searchable manual
database to help technicians diagnose faults and produce structured repair plans.

> **Status: walking skeleton.** The project currently contains the runnable app
> shell, the engine-abstraction layer, and deterministic in-memory fakes for
> every on-device capability. The real on-device backends (LLM, STT, vision) are
> not yet wired in — they slot in behind the interfaces described below.

## What's implemented so far

- **Runnable Flutter app** (iOS + Android) with a Material 3 UI and a single
  home screen.
- **Riverpod dependency injection** (`ProviderScope`) as the seam for swapping
  fakes for real on-device engines without touching upstream code.
- **Engine abstraction layer** — a Dart interface per on-device capability:
  - `LlmEngine` — streams both text tokens **and** structured tool-call events
    (`LlmToken`, `LlmToolCall`, `LlmDone`), mirroring a native function-calling
    runtime.
  - `SttEngine` — consumes a 16-bit mono PCM stream and emits partial/final
    transcripts.
  - `VisionEngine` — decodes barcodes/QR codes and OCR text from image bytes.
  - `PlatformTelemetry` — exposes device thermal state and battery status.
- **Deterministic fakes** for each engine, enabling fast, device-free unit tests
  and driving the skeleton UI.
- **Home screen** that exercises the `LlmEngine` streaming contract end-to-end
  against the fake engine (initialise → stream a scripted response token by
  token → render).
- **Seed dataset** (`assets/elevator_manual_seed.json`) — three Apex-9 manual
  entries (fault code, symptoms, procedure, required tools/parts) used to seed
  the local manual database.
- **Test suite** — a widget smoke test plus unit tests for all four fakes.
- **CI** — GitHub Actions running `dart format`, `flutter analyze`, and
  `flutter test` on every push and pull request.

## Architecture

The app follows a Model–View–ViewModel–Controller (MVVMC) separation, with all
device-specific capabilities hidden behind Dart interfaces:

```
lib/
├── main.dart                 # Entry point; wraps the app in ProviderScope
├── app.dart                  # MaterialApp + theme
├── views/
│   └── home_screen.dart      # Skeleton UI exercising the LlmEngine stream
└── engines/
    ├── llm_engine.dart       # LlmEngine interface + event/tool types
    ├── stt_engine.dart       # SttEngine interface
    ├── vision_engine.dart    # VisionEngine interface
    ├── platform_telemetry.dart
    ├── providers.dart        # Riverpod providers (bind fakes today)
    └── fakes/                # In-memory implementations for tests + skeleton
```

**Why an engine-abstraction seam?** Every heavyweight, device-dependent
capability (model inference, transcription, vision) sits behind a small Dart
interface. Unit tests inject the deterministic fakes and run in pure Dart;
on-device implementations are injected at runtime by overriding the providers in
`ProviderScope`. Nothing upstream depends on a concrete backend.

## Getting started

Requires the Flutter SDK (stable channel, Dart 3.12+).

```bash
flutter pub get
flutter run
```

Tap **Run self-test** on the home screen to stream a scripted response through
the `LlmEngine` contract.

## Testing

```bash
flutter analyze
flutter test
```

Tests are split into two tiers:

- **Unit tier** (`test/`) — pure Dart, deterministic, runs in CI on every commit
  (engine fakes, widget smoke test).
- **Integration tier** — reserved for on-device runs against real backends
  (LLM, STT, vision) using recorded fixtures; added as those backends land.

## Tech stack

| Concern            | Choice                                             |
|--------------------|----------------------------------------------------|
| UI framework       | Flutter (Material 3)                               |
| State management   | Riverpod (`flutter_riverpod`)                      |
| Architecture       | MVVMC with engine-abstraction interfaces           |
| Testing            | `flutter_test` (unit + widget), `integration_test` |
| CI                 | GitHub Actions                                     |

## License

Not yet specified.
