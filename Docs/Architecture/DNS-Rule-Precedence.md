# DNS rule precedence

VayuSetu's on-device DNS filter decides each lookup from a compact snapshot of four rule sets: block-suffix, block-exact, allow-suffix and allow-exact.

## The rule

1. **Allow beats block.** If any allow rule matches the name, the lookup is allowed, however specific the matching block rule is.
2. **Suffix rules cover the domain and every subdomain.** `example.com` covers `example.com`, `www.example.com` and `a.b.example.com`. A suffix matches whole labels only, so `example.com` does not cover `notexample.com`.
3. **Exact rules cover only that name,** not its subdomains.
4. **Anything else that matches a block rule is blocked.** A name that matches nothing is passed to the resolver unchanged.

Identical-priority conflicts (the same name in both an allow and a block set) therefore resolve to allow.

## Why allow always wins

Website Exceptions turn filtering off for one site by adding an allow-suffix rule for it. The exception has to cover the whole site, including subdomains that downloaded lists block (`ads.news.site`, `cdn.tracker.news.site`). A "most specific rule wins" policy would let those list rules block part of a site the user exempted.

## Not implemented: tiers

The snapshot stores no information about where a rule came from, so it cannot rank "your own rules" above "downloaded lists" or use specificity inside a tier. A tiered policy (user decisions override lists, specificity decides within a tier) needs a new snapshot format with a migration and compatibility plan, and the Go DNS filter must read it as well. Until then this document is the contract.

## Tests

`ios/Tests/DNSOnlyTests.swift` pins this behavior: parent allow with a blocked subdomain, blocked parent with an allowed subdomain, exact allow and exact block, an identical-priority conflict, a Website Exception, label boundaries, and a check that the decisions survive encoding and decoding of the stored snapshot.
