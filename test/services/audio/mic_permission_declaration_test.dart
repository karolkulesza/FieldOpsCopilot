import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A source-level guard on the two platform declarations microphone capture
/// cannot run without.
///
/// Neither is Dart, so neither is reachable from any other test in this suite,
/// and both fail in a way that does *not* look like a missing declaration:
///
/// * on iOS, an absent `NSMicrophoneUsageDescription` terminates the process the
///   first time an `AVAudioSession` is activated for recording. Not a denial, not
///   an exception — the app disappears the moment the technician taps the mic;
/// * on Android, an absent `RECORD_AUDIO` makes the runtime request fail
///   immediately with no dialog, so `hasPermission()` reports a denial the user
///   cannot fix, because there is no toggle in Settings for a permission the app
///   never declared.
///
/// Both are one line, both are easy to lose in a merge or a platform-folder
/// regeneration, and the failure of each is loudest on the device it is hardest
/// to debug on. So they are asserted where they cost nothing: in CI, on every
/// commit.
///
/// The Android side is asserted on the **app manifest** rather than the merged
/// one. That is the file this repository owns; a merged manifest would also pass
/// on a permission some plugin happens to contribute today and drops tomorrow,
/// which is a weaker property than the one wanted here.
void main() {
  group('iOS', () {
    late String plist;

    setUpAll(() {
      plist = File('ios/Runner/Info.plist').readAsStringSync();
    });

    test('declares NSMicrophoneUsageDescription', () {
      expect(
        plist,
        contains('<key>NSMicrophoneUsageDescription</key>'),
        reason:
            'without it, iOS kills the process on the first record '
            'activation rather than reporting a denied permission',
      );
    });

    test('the usage description is a non-empty string', () {
      // An empty string satisfies the key and still fails App Review, and — more
      // to the point here — shows the technician a permission prompt with no
      // explanation of why a maintenance app wants their microphone.
      final match = RegExp(
        r'<key>NSMicrophoneUsageDescription</key>\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(plist);

      expect(
        match,
        isNotNull,
        reason: 'the key must be followed by a <string>',
      );
      expect(match!.group(1)!.trim(), isNotEmpty);
    });

    test('the description says the audio stays on the device', () {
      // The app's whole claim is offline-first. A usage string that does not say
      // so invites exactly the objection the architecture exists to answer.
      final match = RegExp(
        r'<key>NSMicrophoneUsageDescription</key>\s*<string>(.*?)</string>',
        dotAll: true,
      ).firstMatch(plist);

      expect(match!.group(1)!.toLowerCase(), contains('locally'));
    });
  });

  group('Android', () {
    test('declares the RECORD_AUDIO permission', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(
        manifest,
        matches(
          RegExp(
            r'<uses-permission\s+android:name\s*=\s*'
            r'"android\.permission\.RECORD_AUDIO"\s*/>',
          ),
        ),
        reason:
            'a runtime permission still needs its manifest declaration; '
            'without it the request is refused with no dialog at all',
      );
    });
  });
}
