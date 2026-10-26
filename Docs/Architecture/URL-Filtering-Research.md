# URL filtering (`NEURLFilterManager`): research result

**Decision: not built. Do not start until the blockers below are cleared.** This is the result of a timeboxed look, not a prototype.

## What it is

In iOS 26 and macOS 26 a content filter can decide on the whole **URL**, not just the host. That is the one way to block an ad whose address is on a site that also serves things you want (a path such as `/ads/`), which DNS filtering cannot do. Apple's design hides what you browse from the filter's vendor: the app keeps a local Bloom filter, and only a possible hit is looked up on a server, using *private information retrieval* through an Oblivious HTTP relay. See the [WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/234/).

## What I could check

- **The SDK.** The installed macOS 27 and iOS SDKs contain `NEURLFilter.h`, which is the small *participant* API (`NEURLFilter.verdict(for:)`, which asks the system for a verdict for a URL). They contain **no header for `NEURLFilterManager`** or the control provider that sets a filter up. I looked for it and did not find it, so I cannot compile a configuration against it here.
- **What a filter needs to run.** From Apple's session and forum threads (not from a header): the `url-filter-provider` entitlement, a **PIR server** you run or rent, a **Privacy Pass issuer**, and an auth token, passed to `NEURLFilterManager`.

## Blockers

1. **A server is required.** A PIR service and a Privacy Pass issuer are server software that someone must host. VayuSetu has promised *no servers, no accounts, no analytics*. This feature cannot be built without breaking that promise, or at least without the user running their own server. Apple publishes an example PIR service, so a self-hosted option is conceivable, but it is a product of its own.
2. **Entitlement approval.** A [forum thread](https://developer.apple.com/forums/thread/815702) reports that export validation rejected the `url-filter-provider` value for an App Store build, even with Network Extensions enabled and profiles regenerated. I found no resolution.
3. **Production-only failures.** Another report says development-signed builds worked but production and TestFlight builds failed with `serverSetupIncomplete` (code 9), because no privacy proxy was provisioned for the bundle ID, and that the filter then failed closed. A later [thread](https://developer.apple.com/forums/thread/791352?page=4) says it was mostly fixed but the manager still broke after restarts, OS updates and TestFlight installs. A filter that fails closed would cut off browsing.
4. **Memory.** An early consumer app reported hitting a 6 MB limit building its Bloom filter inside the extension. VayuSetu's lists are far larger than that.
5. **iOS needs the organization account first.** The App Review decision about VPN apps gates anything shipped on the iPhone.

## What would change the answer

- A header and sample in the full SDK that I could not find, plus an entitlement that Apple grants to our team.
- A decision to let the user point VayuSetu at a PIR server of their own (an advanced option), which keeps "no servers of ours".
- Reports that production signing works reliably.

## What to do instead

Safari content blockers already match full URLs in Safari, and DNS filtering covers other apps by name. Improving the Annoyances and Ads lists, and the rule budget display, gives most of the benefit without any of the above.
