import Foundation

@main struct CoreTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        checks += 1
    }
    static func rejects(_ text: String, _ name: String) {
        do { _ = try ProfileParser.parse(text); fatalError("Accepted invalid profile: \(name)") }
        catch { checks += 1 }
    }
    static func main() throws {
        let key = Data(repeating: 42, count: 32).base64EncodedString()
        let valid = """
        [Interface]
        PrivateKey = \(key)
        Address = 10.0.0.2/32, fd00::2/128
        DNS = 1.1.1.1, 2606:4700:4700::1111
        [Peer]
        PublicKey = \(key)
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = vpn.example.com:51820
        PersistentKeepalive = 25
        """
        let result = try ProfileParser.parse(valid)
        expect(result.peerCount == 1 && result.fullTunnel && result.addresses.count == 2, "valid dual-stack profile")
        rejects(valid.replacingOccurrences(of: "PrivateKey = \(key)", with: "PrivateKey = bad"), "invalid private key")
        rejects(valid.replacingOccurrences(of: "10.0.0.2/32", with: "10.0.0.2/33"), "CIDR overflow")
        rejects(valid.replacingOccurrences(of: "51820", with: "65536"), "port overflow")
        rejects(valid + "\nPostUp = touch /tmp/test", "shell hook")
        rejects(valid + "\nPublicKey = \(key)", "duplicate key")
        rejects("[Peer]\nPublicKey = \(key)", "missing interface")
        rejects(valid.replacingOccurrences(of: "2606:4700:4700::1111", with: "bad-ip"), "invalid DNS")
        rejects(valid.replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = -1"), "negative keepalive")
        expect(ProfileParser.validEndpoint("[2001:db8::1]:51820"), "IPv6 endpoint")
        expect(!ProfileParser.validEndpoint("2001:db8::1:51820"), "unbracketed IPv6 rejected")
        expect(!(try ProfileParser.parse(valid.replacingOccurrences(of: ", ::/0", with: ""))).fullTunnel, "IPv4-only profile not labeled dual-stack")
        let multi = valid + "\n[Peer]\nPublicKey = \(Data(repeating: 43, count: 32).base64EncodedString())\nAllowedIPs = 192.168.0.0/16\nEndpoint = second.example.com:51820"
        expect(try ProfileParser.parse(multi).peerCount == 2, "multiple peers")
        _ = try DNSService.endpoint("https://dns.controld.com/test-resolver")
        for bad in ["http://dns.controld.com/test", "https://dns.controld.com/test?secret=yes", "https://user@dns.controld.com/test", "https://dns.controld.com:443/test"] {
            do { _ = try DNSService.endpoint(bad); fatalError("Accepted unsafe endpoint") } catch { checks += 1 }
        }
        for endpoint in ["https://cloudflare-dns.com/dns-query", "https://dns.google/dns-query", "https://dns.nextdns.io/test-id", "https://resolver.example/custom/path"] {
            expect(try DNSService.endpoint(endpoint).scheme == "https", "custom DoH endpoint")
        }
        for endpoint in ["https://bad_host.example/dns-query", "https://resolver.example/", "https://resolver.example/dns-query#token", "https://resolver.example:8443/dns-query", "https://resolver.example/dns query"] {
            do { _ = try DNSService.endpoint(endpoint); fatalError("Accepted unsafe custom endpoint") } catch { checks += 1 }
        }
        expect(DNSService.query(id: 0x1234).count == 29, "DNS request encoding")
        var reply = [UInt8](DNSService.query(id: 0x1234)); reply[2] = 0x81; reply[3] = 0x80; reply[7] = 1; reply += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 93, 184, 216, 34]
        expect(try DNSService.validateReply(Data(reply), id: 0x1234) == 1, "matching response")
        do { _ = try DNSService.validateReply(Data(reply), id: 0x1235); fatalError("Accepted wrong request ID") } catch { checks += 1 }
        do { _ = try DNSService.validateReply(Data([1, 2]), id: 0x1234); fatalError("Accepted short response") } catch { checks += 1 }
        reply[3] = 0x83
        do { _ = try DNSService.validateReply(Data(reply), id: 0x1234); fatalError("Accepted NXDOMAIN") } catch { checks += 1 }
        var truncated = [UInt8](DNSService.query(id: 0x1234)); truncated[2] = 0x81; truncated[3] = 0x80; truncated[7] = 1
        do { _ = try DNSService.validateReply(Data(truncated), id: 0x1234); fatalError("Accepted fake answer count") } catch { checks += 1 }
        var pointerLoop = truncated; pointerLoop[12] = 0xc0; pointerLoop[13] = 12
        do { _ = try DNSService.validateReply(Data(pointerLoop), id: 0x1234); fatalError("Accepted pointer loop") } catch { checks += 1 }
        rejects(valid + "\n[Peer]\nPublicKey = \(key)\nAllowedIPs = 10.1.0.0/16\nEndpoint = other.example.com:51820", "duplicate public key")
        rejects(valid.replacingOccurrences(of: "10.0.0.2/32", with: ",10.0.0.2/32"), "empty address entry")
        let exported = ProfileExport.redacted(valid + "\nPresharedKey = \(key) # credential-note\n# password-here")
        expect(exported.contains("PrivateKey = [REDACTED]") && exported.contains("PresharedKey = [REDACTED]"), "secret key fields redacted")
        expect(!exported.contains("credential-note") && !exported.contains("password-here"), "comments omitted from exports")
        expect(exported.contains("PublicKey = \(key)") && exported.contains("Endpoint = vpn.example.com:51820"), "nonsecret configuration retained")
        expect(ProfileExport.redacted("  PRIVATEKEY = secret\n pReShArEdKeY=secret2").contains("secret") == false, "case and whitespace cannot defeat redaction")
        rejects(exported, "redacted export cannot connect")
        expect(ProfileParser.canonicalCIDR("10.0.0.2/24") == ProfileParser.canonicalCIDR("10.0.0.0/24"), "IPv4 route normalization")
        expect(ProfileParser.canonicalCIDR("2001:db8::1/64") == ProfileParser.canonicalCIDR("2001:db8::/64"), "IPv6 route normalization")
        expect(ProfileParser.canonicalCIDR("10.0.0.0/24") != ProfileParser.canonicalCIDR("10.0.1.0/24"), "distinct routes preserved")
        let conflict = multi.replacingOccurrences(of: "192.168.0.0/16", with: "10.5.0.0/0")
        rejects(conflict, "two peers cannot claim the same canonical route")
        try ProfileParser.validateTunnel(result); checks += 1
        let split = try ProfileParser.parse(valid.replacingOccurrences(of: "0.0.0.0/0", with: "10.0.0.0/8"))
        do { try ProfileParser.validateTunnel(split); fatalError("Accepted unsupported split tunnel") } catch { checks += 1 }
        let ipv6only = try ProfileParser.parse(valid.replacingOccurrences(of: "10.0.0.2/32, ", with: ""))
        do { try ProfileParser.validateTunnel(ipv6only); fatalError("Accepted unsupported IPv6-only tunnel") } catch { checks += 1 }
        var ipv6Reply = [UInt8](DNSService.query(id: 0x2234, recordType: .aaaa))
        ipv6Reply[2] = 0x81; ipv6Reply[3] = 0x80; ipv6Reply[7] = 1
        ipv6Reply += [0xc0, 0x0c, 0, 28, 0, 1, 0, 0, 0, 60, 0, 16] + [UInt8](repeating: 1, count: 16)
        expect(try DNSService.validateReply(Data(ipv6Reply), id: 0x2234, recordType: .aaaa) == 1, "AAAA record validated")
        do { _ = try DNSService.validateReply(Data(ipv6Reply), id: 0x2234); fatalError("Accepted mismatched question type") } catch { checks += 1 }
        ipv6Reply[40] = 15
        do { _ = try DNSService.validateReply(Data(ipv6Reply), id: 0x2234, recordType: .aaaa); fatalError("Accepted malformed AAAA length") } catch { checks += 1 }
        print("Passed \(checks) core checks.")
    }
}
