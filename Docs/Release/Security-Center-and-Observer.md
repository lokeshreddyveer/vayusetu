# VayuSetu Security Center and optional observer

## What is included

- **Routing visibility:** shows saved full-network capture, route enforcement, local-network, APNs, cellular-service, device-communication, and on-demand settings. These are configuration values, not proof of packet-level fail-closed behavior. Development builds may keep device communication outside the tunnel so Xcode can reach the phone.
- **Independent observer client:** accepts an HTTPS endpoint controlled by the user, sends a one-time random nonce, checks the response host and nonce, and displays the source address reported by that service. An optional expected VPN exit IP enables a comparison. This is one app HTTPS request, not a device-wide leak test or proof of DNS routing.
- **Control D profile filters:** uses Control D's documented profile and filter APIs to read and change the Ads & Trackers, Malware, Phishing, and New Domains categories when returned by the selected account. The user must choose the API profile that corresponds to the app's configured resolver. Control D API credentials currently have broad read or write scopes; use a write token only when category changes are wanted. The token is stored in the app's Keychain service and is never put in the VPN extension's shared credential store.
- **Managed Always On guidance:** explains that Apple's managed Always On VPN is an organization/MDM deployment path, not a setting a personal WireGuard app can enable. Deployment requires an administrator, an MDM-enrolled device, a supported IKEv2 configuration, and a compatible server. No placeholder profile or credentials are generated.
- **Targeted-device guidance:** links to Apple's Lockdown Mode and Platform Security guidance. VayuSetu cannot inspect or enable Lockdown Mode.

The existing Checks, diagnostics, resolver testing, and connection-verification screens remain in the app.

## Deploying the optional observer

The observer is not live until the user hosts it. It has no VayuSetu account, stores no per-request history, and does not write request IPs to application logs. It listens only on `127.0.0.1:8787`; put Caddy on the same machine to provide HTTPS, using `Caddyfile.example` as a starting point. It uses Python's standard library and has no third-party dependencies.

1. Obtain a Linux server and a DNS name you control. Point the DNS record at that server and allow inbound TCP 80/443 for Caddy's certificate management and HTTPS.
2. Install Python 3 and Caddy using their official installation guidance. Review the source and Caddyfile before deployment.
3. In `Caddyfile.example`, replace `observer.example.com` with the real DNS name. Keep the observer bound to loopback. Do not expose port 8787 publicly.
4. Start the service under a dedicated, unprivileged service account (`python3 server.py` from this directory), then configure Caddy with the edited Caddyfile and reload it.
5. In VayuSetu → Settings → Security Center, enter the base URL `https://your-real-name`, save it, and run the observer while connected to VayuSetu. Optionally enter the VPN exit IP independently reported by the VPN provider.

The service trusts `X-Forwarded-For` only when the direct TCP peer is loopback and rejects private, loopback, link-local, multicast/non-global and malformed addresses. Caddy must replace the forwarded address with its own observed remote address. If placing a CDN or another proxy in front, configure and audit trusted-proxy handling first; do not simply forward arbitrary client-supplied headers.

## Interpretation

A matching observer address and provider-reported exit is useful corroboration for the app's request on the current route. A mismatch is a reason to investigate. One HTTP request cannot prove all apps or protocols are tunneled, detect every transient leak, establish which DNS server handled system queries, or prove kill-switch behavior when the tunnel fails. Repeat checks on Wi-Fi and cellular, compare with provider records, and use controlled DNS logs for DNS-path validation. The app intentionally labels this as a sample, not a security score.

## Upstream references

- Apple VPN traffic routing and exceptions: <https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic>
- Apple managed VPN deployment and Always On: <https://support.apple.com/guide/deployment/vpn-overview-depae3d361d0/1/web/1.0>
- Apple IKEv2 protocol: <https://developer.apple.com/documentation/networkextension/nevpnprotocolikev2>
- Control D API authentication: <https://docs.controld.com/reference/authentication>
- Control D list profiles: <https://docs.controld.com/reference/get_profiles>
- Control D list profile filters: <https://docs.controld.com/reference/get_profiles-profile-id-filters>
- Control D update a profile filter: <https://docs.controld.com/reference/put_profiles-profile-id-filters-filter-filter>
- Apple Lockdown Mode: <https://support.apple.com/en-us/105120>
