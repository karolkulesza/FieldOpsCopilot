"""The speech-to-text slice: PCM decoding, spoken-digit folding, the recogniser
configuration, the isolate worker protocol, and both engine implementations.

Forty-three rows — the widest set here, because this is the slice where a test
double was measurably kinder than the hardware (see docs/speech-to-text.md), and
the point of the sweep was to find out where else that was true.
"""

# Suites run for every row. One list, not per-row, so a row cannot look green by
# being pointed at a suite that does not exercise it.
SUITES = [
    "test/services/audio",
    "test/engines",
]

MUTATIONS = [
    # --- pcm_samples.dart -------------------------------------------------------
    dict(
        label="M01-fullscale-32767",
        file="lib/services/audio/pcm_samples.dart",
        old="const double int16FullScale = 32768.0;",
        new="const double int16FullScale = 32767.0;",
        count=1,
        expect="'the most negative sample does not leave the documented range'",
    ),
    dict(
        label="M02-endian-big",
        file="lib/services/audio/pcm_samples.dart",
        old="samples[i] = view.getInt16(i * 2, Endian.little) / int16FullScale;",
        new="samples[i] = view.getInt16(i * 2, Endian.big) / int16FullScale;",
        count=1,
        expect="'decodes little-endian, not the host order'",
    ),
    dict(
        label="M03-odd-length-tolerated",
        file="lib/services/audio/pcm_samples.dart",
        old="  if (bytes.length.isOdd) {",
        new="  if (false) {",
        count=1,
        expect="'rejects an odd-length buffer rather than dropping the half sample'",
    ),
    # --- spoken_digits.dart -----------------------------------------------------
    # **Repaired after review round 1.** This row read `= 2;` and went stale when
    # R0-F3 raised the floor to 3. Lowering it back to 2 restores the exact defect the
    # reviewer found, so the row now measures whether the six pinned false positives
    # hold the new value in place.
    dict(
        label="M04-run-floor-2",
        file="lib/services/audio/spoken_digits.dart",
        old="const int minimumDigitRun = 3;",
        new="const int minimumDigitRun = 2;",
        count=1,
        expect="the six R0-F3 rows, each ending 'survives verbatim'",
    ),
    dict(
        label="M04b-run-floor-1",
        file="lib/services/audio/spoken_digits.dart",
        old="const int minimumDigitRun = 3;",
        new="const int minimumDigitRun = 1;",
        count=1,
        expect="'a lone digit word stays a word' and 'a lone O is a letter'",
    ),
    dict(
        label="M05-drop-O-as-zero",
        file="lib/services/audio/spoken_digits.dart",
        old="  'O': '0',\n",
        new="",
        count=1,
        expect="'OH and O both mean zero' and the measured-transcript tests",
    ),
    # --- stt_isolate_worker.dart: the gap bridge -------------------------------
    dict(
        label="M06-gap-after-audio",
        file="lib/services/audio/stt_isolate_worker.dart",
        old=(
            "          final gap = _bridgeSamples(active, precedingGapBytes);\n"
            "          if (gap > 0) {\n"
            "            produced.addAll(engine.acceptSamples(silentSamples(gap)));\n"
            "          }\n"
            "          produced.addAll(engine.acceptSamples(pcm16ToFloat32(bytes)));\n"
        ),
        new=(
            "          final gap = _bridgeSamples(active, precedingGapBytes);\n"
            "          produced.addAll(engine.acceptSamples(pcm16ToFloat32(bytes)));\n"
            "          if (gap > 0) {\n"
            "            produced.addAll(engine.acceptSamples(silentSamples(gap)));\n"
            "          }\n"
        ),
        count=1,
        expect="'a gap is bridged with silence of its own duration, before the audio'",
    ),
    dict(
        label="M07-gap-cap-removed",
        file="lib/services/audio/stt_isolate_worker.dart",
        old="  final bounded = gapBytes < capBytes ? gapBytes : capBytes;",
        new="  final bounded = gapBytes;",
        count=1,
        expect="'a gap longer than the cap is truncated to the cap'",
    ),
    dict(
        label="M08-gap-ignored",
        file="lib/services/audio/stt_isolate_worker.dart",
        old="  if (gapBytes <= 0) return 0;",
        new="  return 0; // ignore every gap",
        count=1,
        expect="'a gap is bridged with silence of its own duration, before the audio'",
    ),
    # --- stt_isolate_worker.dart: the tail padding -----------------------------
    dict(
        label="M09-padding-after-flush",
        file="lib/services/audio/stt_isolate_worker.dart",
        old=(
            "          if (padding > 0) {\n"
            "            produced.addAll(engine.acceptSamples(silentSamples(padding)));\n"
            "          }\n"
            "          produced.addAll(engine.finishSession());\n"
        ),
        new=(
            "          produced.addAll(engine.finishSession());\n"
            "          if (padding > 0) {\n"
            "            produced.addAll(engine.acceptSamples(silentSamples(padding)));\n"
            "          }\n"
        ),
        count=1,
        expect="'pads before flushing' (call order) and the padding-first ordering test",
    ),
    dict(
        label="M10-padding-zero",
        file="lib/services/audio/stt_config.dart",
        old="  static const Duration defaultTailPadding = Duration(milliseconds: 800);",
        new="  static const Duration defaultTailPadding = Duration.zero;",
        count=1,
        expect="'tail padding is non-zero' and 'pads before flushing'",
    ),
    # --- stt_config.dart: the codec --------------------------------------------
    dict(
        label="M11-wire-drops-gap-cap",
        file="lib/services/audio/stt_config.dart",
        old="    'maxGapBridgeMs': maxGapBridge.inMilliseconds,",
        new="    'maxGapBridgeMs': defaultMaxGapBridge.inMilliseconds,",
        count=1,
        expect="'every field survives, including the ones with defaults'",
    ),
    dict(
        label="M12-wire-defaults-instead-of-throwing",
        file="lib/services/audio/stt_config.dart",
        old="    if (raw is int) return raw;\n    throw FormatException('stt config: $field is not an int ($raw)');",
        new="    if (raw is int) return raw;\n    return 0;",
        count=1,
        expect="'a non-int sampleRate'",
    ),
    # --- sherpa_stt_engine.dart: back-pressure and session release -------------
    dict(
        label="M13-no-backpressure",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      subscription.pause();\n",
        new="",
        count=1,
        expect="'a chunk is not sent until the previous one is answered'",
    ),
    dict(
        label="M14-cancel-does-not-release-session",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      settled = true;\n      await input?.cancel();\n      await release(cancelSession: true);\n    };",
        new="      settled = true;\n      await input?.cancel();\n      await release(cancelSession: false);\n    };",
        count=1,
        expect="'when the consumer walks away mid-utterance'",
    ),
    # **Repaired after review round 2.** This row was keyed to
    # `if (cancelSession && begun) {`, which R1-F1's fix restructured into an early
    # return plus the in-flight-begin await. The property is unchanged — a session that
    # was never opened must not be cancelled — so the row now removes the guard in its
    # new form.
    # **Repaired twice.** Round 1 restructured `release` and this row went stale;
    # round 2 then found the line it had been retargeted to (`if (!begun) return;`)
    # was dead — every path reaching it had `begun == true`. The property lives in
    # the failed-begin catch, so that is what the row removes now.
    dict(
        label="M15-cancel-a-session-never-begun",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="          // property actually lives.\n          return;",
        new="          // property actually lives.",
        count=1,
        expect="'a begin that failed is not cancelled'",
    ),
    dict(
        label="M16-transcribing-slot-leaks",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      if (!_transcribing) return;\n      _transcribing = false;",
        new="      if (!_transcribing) return;",
        count=1,
        expect="'a completed transcription releases the slot'",
    ),
    dict(
        label="M17-normalise-only-finals",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="  SttTranscript _toTranscript(SttTranscriptWire wire) => SttTranscript(\n    normalizeSpokenDigits(wire.text),",
        new="  SttTranscript _toTranscript(SttTranscriptWire wire) => SttTranscript(\n    wire.isFinal ? normalizeSpokenDigits(wire.text) : wire.text,",
        count=1,
        expect="'partials are normalised too, not only finals'",
    ),
    dict(
        label="M18-rawText-loses-the-original",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="    rawText: wire.text,",
        new="    rawText: normalizeSpokenDigits(wire.text),",
        count=1,
        expect="'spoken digits are rewritten in text and kept in rawText'",
    ),
    dict(
        label="M19-overlapping-loads-not-shared",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="    _loading ??= _host.start(config);",
        new="    _loading = _host.start(config);",
        count=1,
        expect="'overlapping initialize calls share one load'",
    ),
    dict(
        label="M20-second-transcription-allowed",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="    if (_transcribing) {\n      throw StateError('a transcription is already in flight');\n    }",
        new="",
        count=1,
        expect="'refuses a second concurrent transcription' (engine and fake)",
    ),
    # --- fake parity -----------------------------------------------------------
    dict(
        label="M21-fake-revives-after-dispose",
        file="lib/engines/fakes/fake_stt_engine.dart",
        old="    if (_disposed) {\n      throw StateError('FakeSttEngine was disposed; create a new instance');\n    }\n",
        new="",
        count=1,
        expect="'refuses use after disposal, and refuses to be revived'",
    ),
    # **Repaired after review round 1.** The old row deleted `await frames.drain()`,
    # which R0-F1's rewrite removed. The *property* it was binding — the fake does not
    # emit until the frame stream closes, because the real engine cannot produce a
    # final before `finishSession` — survives the rewrite, so the row now breaks the
    # ordering directly by emitting on the first frame instead.
    dict(
        label="M22-fake-emits-on-first-frame",
        file="lib/engines/fakes/fake_stt_engine.dart",
        old="      input = frames.listen(\n        (_) {},",
        new="      input = frames.listen(\n        (_) => emitScript(),",
        count=1,
        expect="'the script is not emitted until the frame stream closes'",
    ),
    # --- the worker's not-loaded guards ---------------------------------------
    dict(
        label="M23-audio-before-load-crashes",
        file="lib/services/audio/stt_isolate_worker.dart",
        old="        if (active == null || engine == null) {\n          reply?.send(_notLoaded('audio').toWire());\n          continue;\n        }",
        new="        if (active == null || engine == null) {\n          continue;\n        }",
        count=1,
        expect="'audio before a load is refused by name' (it would hang instead)",
    ),
    dict(
        label="M24-shutdown-skips-cancel",
        file="lib/services/audio/stt_isolate_worker.dart",
        old="          try {\n            active.cancelSession();\n          } on Object catch (error) {\n            debugPrint('[stt worker] cancel during shutdown failed: $error');\n          }\n",
        new="",
        count=1,
        expect="'shutdown cancels first, then closes, then returns'",
    ),
    # ======================================================================
    # Rows added after review round 1, over the code the *fixes* introduced.
    #
    # Task 2.1's row records why this block exists at all: six of its fifteen findings
    # were claims or values introduced in a fixing round with nothing holding them, and
    # the only one caught before handback was the one whose mutation was run after the
    # fix rather than before. Two of these (N08, N09) are the reviewer's own surviving
    # mutations, kept as rows so the regression cannot come back quietly.
    # ======================================================================
    dict(
        label="N01-prefixed-floor-3",
        file="lib/services/audio/spoken_digits.dart",
        old="const int minimumPrefixedDigitRun = 2;",
        new="const int minimumPrefixedDigitRun = 3;",
        count=1,
        expect="'a single-letter designator lowers the floor to two'",
    ),
    dict(
        label="N02-designator-ignores-punctuation",
        file="lib/services/audio/spoken_digits.dart",
        old="      if (previous.text.trim().isNotEmpty) return false;",
        new="      continue;",
        count=1,
        expect="'a designator separated by punctuation does not lower the floor'",
    ),
    dict(
        label="N03-no-designator-ever",
        file="lib/services/audio/spoken_digits.dart",
        old="      if (previous.isWord) return previous.text.length == 1;",
        new="      if (previous.isWord) return false;",
        count=1,
        expect="'a single-letter designator lowers the floor to two'",
    ),
    dict(
        label="N04-two-letter-words-count-as-designators",
        file="lib/services/audio/spoken_digits.dart",
        old="      if (previous.isWord) return previous.text.length == 1;",
        new="      if (previous.isWord) return previous.text.length <= 2;",
        count=1,
        expect="'a two-letter word does not lower the floor' (NO-12 / IS-01)",
    ),
    dict(
        label="N05-run-swallows-punctuation-again",
        file="lib/services/audio/spoken_digits.dart",
        old="        if (candidate.text.trim().isNotEmpty) break;",
        new="",
        count=1,
        expect="'a digit already in the text is not swallowed'",
    ),
    dict(
        label="N06-fake-cancel-does-not-release",
        file="lib/engines/fakes/fake_stt_engine.dart",
        old="      settled = true;\n      await input?.cancel();\n      release();\n    };",
        new="      settled = true;\n      await input?.cancel();\n    };",
        count=1,
        expect="'cancelling mid-utterance completes, and releases'",
    ),
    dict(
        label="N07-fake-never-takes-the-slot",
        file="lib/engines/fakes/fake_stt_engine.dart",
        old="      _transcribing = true;\n      // The audio is consumed to completion",
        new="      // The audio is consumed to completion",
        count=1,
        expect="'refuses a second concurrent transcription'",
    ),
    dict(
        label="N08-wire-drops-native-library-path",
        file="lib/services/audio/stt_config.dart",
        old="    'nativeLibraryPath': nativeLibraryPath,",
        new="    'nativeLibraryPath': null,",
        count=1,
        expect="'every field survives, including the ones with defaults' (R0-F5)",
    ),
    dict(
        label="N09-empty-library-path-accepted",
        file="lib/services/audio/stt_config.dart",
        old="    if (raw == null) return null;\n    if (raw is String && raw.isNotEmpty) return raw;",
        new="    if (raw == null) return null;\n    if (raw is String) return raw;",
        count=1,
        expect="'an empty nativeLibraryPath — refused rather than read as null' (R0-F5)",
    ),
    dict(
        label="N10-engine-onlisten-guard-removed",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      if (_transcribing) {\n        // Only reachable when two streams were built before either was listened to;",
        new="      if (false) {\n        // Only reachable when two streams were built before either was listened to;",
        count=1,
        expect="'two streams built before either is listened to: the second errors'",
    ),
    dict(
        label="N11-engine-takes-slot-at-call-site",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="    if (_transcribing) {\n      throw StateError('a transcription is already in flight');\n    }\n    return _transcribe(frames);",
        new="    if (_transcribing) {\n      throw StateError('a transcription is already in flight');\n    }\n    _transcribing = true;\n    return _transcribe(frames);",
        count=1,
        expect="'a stream that is never listened to does not wedge the engine' (R0-F6)",
    ),
    dict(
        label="N12-fake-takes-slot-at-call-site",
        file="lib/engines/fakes/fake_stt_engine.dart",
        old="    if (_transcribing) {\n      throw StateError('a transcription is already in flight');\n    }\n    return _transcribe(frames);",
        new="    if (_transcribing) {\n      throw StateError('a transcription is already in flight');\n    }\n    _transcribing = true;\n    return _transcribe(frames);",
        count=1,
        expect="the fake's 'a stream that is never listened to does not wedge the engine'",
    ),
    # ======================================================================
    # Rows added after review round 2, over the code that round's fixes introduced.
    # R1-F1 is the reason this block is not optional: the previous round's cancel-path
    # rows (M14, M15) both passed while a real session leaked, because the scripted
    # host could not suspend where the real one does.
    # ======================================================================
    dict(
        label="P01-cancel-ignores-inflight-begin",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      final pending = beginning;",
        new="      final Future<void>? pending = null;",
        count=1,
        expect="'a cancel landing mid-beginSession still releases the session'",
    ),
    dict(
        label="P02-begin-future-never-published",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      beginning = begin;",
        new="",
        count=1,
        expect="'a cancel landing mid-beginSession still releases the session'",
    ),
    dict(
        label="P05-begin-call-hoisted-out-of-try",
        file="lib/engines/impl/sherpa_stt_engine.dart",
        old="      try {\n        // Published *before* it is awaited,",
        new=(
            "      final hoisted = _host.beginSession();\n"
            "      beginning = hoisted;\n"
            "      try {\n        // Published *before* it is awaited,"
        ),
        count=1,
        expect="'a beginSession that throws synchronously is reported, not lost'",
    ),
    # P03 and P04 were drafted and removed after their first run, and both removals
    # are findings rather than tidying. P03 inserted `begun = true` immediately
    # before a `return`, so it changed nothing — 1.9's "a mutation that does not
    # mutate measures the mutation, not the suite". P04 targeted an `if (!settled)`
    # guard that the same run showed was dead, and it has been deleted from the
    # source rather than kept as decoration.
    # A row over `integration_test/stt_test.dart`'s corrected bound was drafted and
    # deliberately dropped: that directory is outside [SUITES] by design (`flutter test`
    # does not pick it up, which is what keeps CI host-only), so the row would survive
    # by construction and make "0 survived" mean two different things. The device
    # test's assertion is unbound on the host, and that is a property of the tier
    # rather than a gap this harness can close — stated in the ledger instead.
]


