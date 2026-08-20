/// The technician inquiries the device suite drives, in one place so the host
/// suite can check their **premises** without a device.
///
/// This file deliberately imports nothing — not `package:integration_test`, not
/// the app — so `test/` can import it too. That is the whole point: the device
/// run costs a build, a 2.6GB transfer and several minutes, and it should never
/// spend all of that to discover that a fixture no longer means what its name
/// says.
///
/// It exists because that is exactly what happened. TC-AGENT-E2E-01b asserts
/// that an out-of-scope inquiry retrieves nothing, and its first fixture — "the
/// hydraulic ram on the loading crane is leaking" — retrieved two entries, so
/// the test failed on its premise on device without the model ever running.
/// Two independent reasons, and the second is the one that matters:
///
/// 1. `hydraulic` is in the manual. E-204 is *Proportional Valve Flow
///    Discrepancy*, whose symptoms name the "hydraulic manifold". Choosing a
///    hydraulic term as the out-of-domain word for an elevator manual was
///    simply wrong.
/// 2. **Stop words match.** `the`, `on` and `is` each retrieve entries on their
///    own, because the FTS query sanitizer joins terms with `OR` and FTS5's
///    `porter` tokenizer removes no stop words. So the fixture would have
///    matched even with `hydraulic` removed — and so does almost any English
///    sentence. See the README's note; that is a retrieval finding, not a
///    fixture one, and it is recorded rather than worked around here.
library;

/// The happy path: a fault the manual covers, needing a part the warehouse has.
const String e2eGroundedInquiry = 'cabin vibrating, E-102';

/// An inquiry the manual genuinely has no entry for.
///
/// Same input TC-RAG-COMP-01 uses, and for the same reason — it is
/// the one phrasing verified to leave both retrieval legs empty against the
/// shipped seed. It reads less like something a technician would type than the
/// fixture it replaced; that is the trade, and the alternative is a test whose
/// premise is false. `tc_agent_e2e_premises_test.dart` pins it on the host.
const String e2eNoMatchInquiry = 'unknown machinery broken';
