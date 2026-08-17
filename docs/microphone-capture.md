# Microphone capture

Voice is the demo's differentiator, and it starts with bytes off the microphone.
`MicCapture` (`lib/services/audio/mic_capture.dart`) opens the mic and delivers
**16-bit little-endian mono PCM at 16 kHz** — the format `SttEngine.transcribe`
is declared over, and the rate the streaming zipformer of Task 2.2 wants.

`package:record` does the recording. It sits behind an `AudioInput` interface, the
same seam shape `ModelDownloader` uses, and for the same two reasons: the plugin
is imported by exactly one class, and everything *around* the recording runs in
host tests. That split matters more here than it looks, because almost nothing in
this component is about audio hardware:

| What | Where it is decided | How it is checked |
|---|---|---|
| Permission, and the difference between a refusal and a failure to ask | `MicCapture.start` | host |
| No empty buffers, no split samples | `MicCaptureSession._onRawBuffer` | host |
| A bounded backlog, and dropped audio the consumer cannot miss | `MicCaptureSession._enqueue` | host |
| Draining the tail of an utterance on `stop` | `MicCaptureSession.stop` | host |
| A format the platform substituted | `RecordAudioInput.describeFormatMismatch` | host (the decision), device (the wiring) |
| Real hardware produces real PCM at the right cadence | the device | **TC-MIC-01** |

## Four things read out of the plugin's source

Every one of these is a claim about `record` 7.1.1 / `record_ios` 2.1.1 /
`record_android` 2.1.2, arrived at by reading those packages rather than their
READMEs — Task 1.8's rule, which cost that task six review findings to learn.

**The stream has no backpressure, and drops what arrives before you listen.**
`AudioRecorder.startStream` returns a `StreamController.broadcast()` fed from a
platform callback (`_StreamMixin._startRecordStream`), and it `add`s only
`when ctrl.hasListener`. So buffers captured before the first `listen` are gone,
and a subscriber that pauses buffers audio in its subscription with no ceiling.
Both are the session's problem to solve: it subscribes immediately and holds a
**bounded** backlog, two seconds by default.

When that bound is hit the *oldest* audio goes, never the newest — a live
recogniser that falls behind should come back at the present moment with a gap
behind it rather than accumulate lag it can never pay off — and the newest buffer
is always kept, so a bound smaller than one platform buffer degrades to
latest-only instead of to nothing.

**Dropped audio travels with the audio.** `MicFrame.precedingGapBytes` carries
what was lost immediately before that frame. This is the one design choice here
worth arguing about, and the argument is that the alternative failure is
invisible: a recogniser fed a silently spliced stream returns a fluent,
well-formed transcript of a sentence nobody said. A counter on the session
(`droppedByteCount`, also present) is something a consumer has to remember to
read; a field on the frame is in their hands at the moment it matters.

**A second `startStream` closes the first one silently.** `AudioRecorder.startStream`
calls `_stopRecordStream()` before opening (`record` 7.1.1), which closes the
previous controller — so the first consumer's stream *ends with no error*, a
transcript that just stops mid-sentence. `MicCapture.start` therefore answers
`MicCaptureBusy` rather than restarting, and a start after a stop waits on
`MicCaptureSession.released`, because `isCapturing` goes false when the stop is
*asked for* and the recorder comes back later than that.

**`streamBufferSize` means different things on the two platforms, so it is left
unset.** `record_ios` passes it to `AVAudioNode.installTap` as an
`AVAudioFrameCount` — sample *frames*, defaulting to 1024. `record_android` passes
it to `AudioRecord` as `bufferSizeInBytes`. One number cannot mean both, so each
platform keeps its own default rather than this app picking a figure that is right
on one of them.

## The defect the host suite found

`stop()` originally cancelled the raw subscription and *then* released the input.
Buffers the plugin has already handed to its stream but not yet dispatched die
with the subscription, so every capture lost its tail — the last word of "…and the
brake is dragging", every time, with nothing to indicate it had happened. Six
tests failed on it at once.

The order is now: release first, wait for the plugin to close its own stream
(releasing is what closes it), *then* cancel. Which needed one more piece of
state: the window between "stop was asked for" and "no more audio will be
accepted" is precisely where those buffers arrive, so a stream `done` inside it is
the expected end rather than a fault. The wait is bounded (`drainGrace`, 250ms) on Task 1.11's
principle that a seam which hangs reports nothing and a frozen UI reads as a
crash; a test drives a plugin that never closes its stream and asserts both halves
— the audio still arrives, and the wait is a bound.

## What is deliberately not here

**Noise suppression**, even though the spec asks for it. `record_ios` 2.1.1 parses
`noiseSuppress` into its `RecordConfig` and never reads it again: the stream
delegate applies only `echoCancel` and `autoGain`, through
`setVoiceProcessingEnabled`. (`record_android` 2.1.2 *does* honour it, via
`AudioEffectsManager`.) Setting it would therefore be decoration on the device
this project is demoed from — a flag that looks like a feature. Ambient-noise
filtering stays in the narrated appendix where the sprint plan puts it.

**A Riverpod provider.** Nothing consumes microphone audio yet; the STT engine is
Task 2.2 and the form is 2.3, and both own UI this task does not. A provider added
now would construct an `AudioRecorder` — which calls a platform channel in its
constructor — for no reader, and could not be host-tested. Tasks 1.3 through 1.10
all shipped unwired for the same reason; the wiring belongs to the task that has
something to wire it to.

## The format-coercion tripwire, live on Android

`RecordAudioInput` registers
`setOnConfigChanged` and faults the capture if the delivered sample rate, channel
count or encoder differs from what was asked for, because 16-bit PCM at the wrong
rate does not error — it transcribes as nonsense, and a capture that cannot be
trusted is worse than no capture. The *decision* is a pure function and is
host-tested, including the case that matters most: the plugin fires that callback
whenever **any** of bit rate, sample rate or channel count was adjusted
(`RecordConfig.isModified`, both platforms), and bit rate does not exist for a raw
PCM stream — neither platform's PCM encoder reads it. Faulting a good capture
because the platform normalised an unused field would make the tripwire worse than
not watching at all. The *wiring* is host-tested too, by impersonating the platform
on `com.llfbandit.record/configChanged/<recorderId>`.

An earlier version of this section said the callback should never fire at all, on
the reasoning that neither stream path mutates the format. **Review finding R0-F3
refuted the Android half.** `FormatCodecSelector.findCodec` calls
`adjustToDeviceCapabilities(config)` *before* its `MIMETYPE_AUDIO_RAW` early
return, and that assigns `config.numChannels` from the routed input's advertised
channel counts — so on an Android device whose default input does not advertise
mono, a mono request is silently coerced to stereo and the tripwire is **live**.
Such a capture is faulted rather than degraded, deliberately: interleaved stereo
handed to a mono recogniser is every second sample from the wrong channel, and this
app does not downmix. Downmixing is the obvious alternative and belongs with
whoever owns the recogniser. iOS genuinely does not coerce — its stream delegate
resamples through `AVAudioConverter` and throws if it cannot.

## Two spec requirements this seam meets by not doing something

§3.2 asks for recorded audio at rest to be encrypted. Capture here is
**stream-only** — no file is ever written, no path is ever handed to the plugin —
so there is no audio at rest to encrypt. That is a requirement satisfied by a
design choice rather than by a mechanism, which is exactly the kind of thing that
looks unimplemented later, so it is written down here.

§3.1 names transcription as isolate work. `MicCapture`'s own per-buffer work runs
on the UI isolate and is O(1) at roughly sixteen buffers a second — a merge, a
remainder and a queue push — so it does not need one. The isolate boundary the spec
asks for belongs to the recogniser, which is Task 2.2, and it consumes the stream
this produces.

## What actually goes wrong, and what does not

Three fault paths existed here before review, and **two of them cannot happen**.
This is worth its own heading because the corrected version is the opposite of the
intuitive one, and because the comment that got it wrong was confident.

`record` 7.1.1's `_startRecordStream` subscribes to the platform stream with
`onData` and `onError` and **no `onDone`**, and neither native side ever ends its
event channel (`endOfStream` and `FlutterEndOfEventStream` appear nowhere in
`record_ios` 2.1.1 or `record_android` 2.1.2). So the broadcast controller the
session listens to closes only when `_stopRecordStream` closes it — from `stop`,
`cancel`, `dispose`, or a second `startStream`. A stream that ends *by itself* is
not a thing the plugin does, and the three causes the code once attributed to it —
a revoked permission, a route change, another app claiming the input — all go
somewhere else:

| What happens | What the app sees | Handled by |
|---|---|---|
| Android read failure | an **error** on the stream | `onError` → `MicCaptureFault` |
| iOS audio-session interruption | **silence** — the engine pauses under `AudioInterruptionMode.pause` and never resumes, tap still installed | `stallTimeout` |
| the plugin closing its stream | `done` **during** `stop` | the normal end, not a fault |
| a stream ending by itself | cannot happen on either platform today | the `onDone` fault, kept as forward-defence for the seam's contract |

The iOS row is the one that mattered, and it had no answer at all. Silence left the
session `isCapturing` with `frames` open forever — and since `SttEngine.transcribe`
consumes `frames` to completion, a phone call mid-dictation meant a transcript that
never arrived, on the device this project is demoed from. `MicCapture.stallTimeout`
(five seconds, `null` to disable) now faults it. It is re-armed by *any* buffer,
including an empty one, because a quiet room is a stream of near-zero samples
rather than an absence of buffers — so what it measures is a dead input, not a
pause in speech.

---

[← Back to the README](../README.md)
