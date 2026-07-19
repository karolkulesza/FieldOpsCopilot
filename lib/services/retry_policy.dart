/// The retry policy for providers whose failure cannot change on its own.
///
/// **This file exists because of a Riverpod 3 default that is wrong for every
/// startup provider in this app.** `ProviderContainer.defaultRetry` retries a
/// provider whose body threw, with exponential backoff — `minDelay` 200ms
/// doubling to a 6.4s `maxDelay`, `maxRetries: 10`. It skips only `Error` and
/// `ProviderException` (riverpod 3.3.2, `provider_container.dart`:
/// `if (error is ProviderException || error is Error) return null;`), so every
/// ordinary `Exception` is retried.
///
/// **Measured rather than derived from those parameters**, by sampling a
/// deliberately-failing `seedOutcomeProvider` with `retry: noRetry` removed:
/// the body ran **11 times** (one attempt plus ten retries) and the element was
/// still `AsyncLoading` at 30s, `AsyncError` by 45s. The arithmetic predicts
/// 38.2s of delay, and the sampling is consistent with it; the sampled figures
/// are what is quoted because they are what was run. It terminates — it is not
/// an unbounded loop — which is the one thing worth knowing that the parameter
/// list does not say outright.
///
/// That default is defensible for a provider that fetches something over a
/// network. It is wrong for the three ways this app's startup fails, because all
/// three are deterministic:
///
/// * a malformed seed asset (`SeedFormatException`) — a build defect; the same
///   bytes parse the same way ten times;
/// * an encryption key that does not open the existing database
///   (`SqliteException`) — the key is compiled in, so attempt ten uses the same
///   key as attempt one;
/// * a platform channel with no implementation (`MissingPluginException`), which
///   is what a host widget test hits and what a misconfigured build hits.
///
/// Retrying any of them costs that half-minute and cannot change the outcome.
/// Worse than the delay is what is on screen during it: the provider stays in
/// `AsyncLoading`, so the UI reports "checking…" the whole time and *then*
/// reports the failure. The seeding layer's contract is that a malformed asset
/// "fails loudly at
/// startup"; a wait that long before the message appears is the opposite of
/// loudly, and it reads as a hang.
///
/// This is the same rule `ModelProvisioningController` already writes down for a
/// download whose bytes failed the pinned digest — "a retry moves the same
/// gigabytes and fails the same way" — applied one layer up. The principle was
/// already in the repo; the framework default just disagreed with it.
///
/// **Scoped per provider rather than set on the container.** `ProviderScope`
/// accepts a container-wide `retry`, which would be one line instead of several,
/// and it would also silently apply to the next provider someone adds — including
/// one that really is transient and really should back off. Naming the policy at
/// each site keeps the claim ("this failure is deterministic") next to the code
/// that has to be true for it.
library;

/// A `Retry` that never retries: the first failure is the answer.
///
/// Use it on a provider whose body has no non-determinism to re-roll — no
/// network, no clock, no external process. Do **not** use it to silence a flaky
/// provider; a flaky provider is a different bug and the backoff default is
/// right for it.
Duration? noRetry(int retryCount, Object error) => null;
