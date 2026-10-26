#!/usr/bin/env python3
"""VayuSetu performance and reliability gate (Mac), schema 3.

Measures the installed app against the real network and compares one run with another. Nothing is mocked: it switches protection on and
off with the app's own vayusetu:// links and times what happens.

    perf_gate.py measure [--runs 3] [--out FILE] [--flap]   measure the installed app, save a result file
    perf_gate.py compare BASELINE CURRENT                   exit 1 if CURRENT is worse than BASELINE beyond the allowed margins
    perf_gate.py show FILE                                  print a result file
    perf_gate.py restore [--to off|dns|vpn|both]            put protection back (after an interrupted run), then verify it

VPN performance is measured in fixed-length downloads (default 5 runs of 15 s), with the tunnel's instantaneous CPU sampled every second, ping
loss and round-trip time while idle and while loaded, and the VPN interface's byte counters. Runs too short to be meaningful are flagged and
left out. Throughput and CPU depend on the VPN server and the network, so they only BLOCK a change when the baseline was merged from at least
two separate sessions (`merge`) and the round-trip time shows the same path; otherwise they are shown as advisory. VPN-only DNS is a provider
quality diagnostic and never blocks.

    perf_gate.py merge OUT FILE1 FILE2 [...]                combine separate sessions of one build into a baseline with its observed spread

Safety: the starting state is written to macos/perf/.restore.json before anything is switched. The whole run is inside try/finally, Ctrl-C
and a termination signal are turned into a normal exit, and the original state is restored and then VERIFIED (VPN and DNS read back from the
system). If it cannot be verified the script exits with status 3 and says so. `restore` does the same from the saved file.

It changes protection while it runs. `--flap` also turns Wi-Fi off for 5 seconds to time reconnection; use it only when you can lose the
network briefly.

What it does not measure: battery. macOS gives no per-process energy figure without administrator rights, so battery is measured on the
iPhone (Xcode's energy gauge) and noted by hand.
"""
import argparse, atexit, datetime, json, os, random, re, signal, socket, statistics, string, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PERF = os.path.join(HERE, "..", "perf")
RESTORE_FILE = os.path.join(PERF, ".restore.json")
SCHEMA = 3
NORMAL_LOAD_MBPS = 30.0       # memory is compared on runs up to this throughput
MEMORY_CEILING_MB = 300        # the tunnel must never exceed this, at any load
LOCAL_DNS = "198.18.0.2"
GOOD = "example.com"
BLOCKED = "pagead2.googlesyndication.com"
SPEED_URL_CHUNK = "https://proof.ovh.net/files/1Gb.dat"   # one long file: speed.cloudflare.com refuses requests over 25 MB (403) and rate-limits repeats (429)
SPEED_URL = "https://speed.cloudflare.com/__down?bytes=30000000"

# Cold lookups ask for a name no cache can hold: a random label under a real domain, so the full path (tunnel, upstream resolver, recursion)
# is exercised. Either an answer or "no such name" counts as a success. Warm lookups use a fixed list that is asked once, unmeasured, first.
COLD_DOMAINS = ["apple.com", "google.com", "youtube.com", "wikipedia.org", "github.com", "cloudflare.com", "amazon.com", "microsoft.com",
                "netflix.com", "reddit.com", "nytimes.com", "bbc.co.uk", "stackoverflow.com", "mozilla.org", "python.org", "swift.org",
                "openai.com", "spotify.com", "twitch.tv", "linkedin.com", "dropbox.com", "slack.com", "zoom.us", "adobe.com", "medium.com"]
WARM_NAMES = ["apple.com", "google.com", "youtube.com", "wikipedia.org", "github.com", "cloudflare.com", "amazon.com", "microsoft.com",
              "netflix.com", "reddit.com", "nytimes.com", "bbc.co.uk", "stackoverflow.com", "mozilla.org", "python.org", "swift.org",
              "openai.com", "spotify.com", "twitch.tv", "linkedin.com"]

DNS_MODES = ("dnsonly", "both", "vpnonly")      # vpnonly is recorded as diag_dns_vpnonly_*, a provider diagnostic
LIMITS = {   # name -> (direction, relative margin, absolute margin). Worse means worse than baseline by more than BOTH margins.
    "connect_dns_s": ("lower", 0.25, 1.0), "connect_vpn_s": ("lower", 0.25, 1.5), "connect_both_s": ("lower", 0.25, 2.0),
    "switch_dns_to_both_s": ("lower", 0.25, 2.0), "stop_s": ("lower", 0.30, 1.0),
    "vpn_throughput_mbps": ("higher", 0.15, 2.0), "vpn_connect_ms": ("lower", 0.30, 25.0),
    "tunnel_cpu_pct": ("lower", 0.30, 1.0), "tunnel_mem_mb": ("lower", 0.25, 5.0),
    "tunnel_failures": ("lower", 0.0, 0.0), "flap_recover_s": ("lower", 0.30, 2.0),
}
LIMITS["app_exits"] = ("lower", 0.0, 0.0)
LIMITS["vpn_cpu_avg_pct"] = ("lower", 0.30, 3.0); LIMITS["vpn_cpu_p95_pct"] = ("lower", 0.30, 5.0); LIMITS["vpn_loss_pct"] = ("lower", 0.0, 1.0)
LIMITS["vpn_rtt_loaded_ms"] = ("lower", 0.25, 15.0)
del LIMITS["tunnel_cpu_pct"], LIMITS["vpn_connect_ms"]
# These depend on the VPN server and the network. They block only with a multi-session baseline and a matching round-trip time.
SENSITIVE = {"vpn_throughput_mbps", "vpn_cpu_avg_pct", "vpn_cpu_p95_pct", "vpn_loss_pct", "vpn_rtt_loaded_ms", "connect_vpn_s", "connect_both_s", "switch_dns_to_both_s"}
DNS_GATED = ("dnsonly", "both")
for _m in DNS_GATED:
    LIMITS[f"dns_{_m}_cold_p50_ms"] = ("lower", 0.30, 2.0)
    LIMITS[f"dns_{_m}_cold_p95_ms"] = ("lower", 0.40, 6.0)
    LIMITS[f"dns_{_m}_warm_p50_ms"] = ("lower", 0.30, 1.0)
    LIMITS[f"dns_{_m}_success_pct"] = ("higher", 0.0, 0.5)


# ---- small helpers -------------------------------------------------------------------------------------------------------------------
def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


APP_EXITS = 0


def app_running(): return bool(sh("pgrep -x VayuSetuVPN").strip())


def ensure_app():
    """VayuSetu has been seen to exit by itself (a voluntary `terminate:`) during runs. Reopen it and count each time, so the problem is
    visible in the result instead of silently stopping the measurement."""
    global APP_EXITS
    if app_running(): return
    APP_EXITS += 1
    print("  VayuSetu was not running; reopening it (counted as an app exit)")
    sh(["open", "/Applications/VayuSetu.app"]); wait(30, app_running); time.sleep(6)


def link(path):
    ensure_app()
    subprocess.run(["open", "vayusetu://protection/" + path])


def wait(limit, test, step=0.25):
    start = time.time()
    while time.time() - start < limit:
        if test():
            return time.time() - start
        time.sleep(step)
    return None


def now_iso():
    return datetime.datetime.now().isoformat(timespec="seconds")


# ---- what the system says about protection (this is what "restored" is checked against) -----------------------------------------------
def nc_line():
    for line in sh("scutil --nc list").splitlines():
        if "app.vayusetu.macos" in line:
            return line
    return ""


def nc_connected(): return "(Connected)" in nc_line()
def nc_busy(): return any(s in nc_line() for s in ("(Connected)", "(Connecting)", "(Reasserting)", "(Disconnecting)"))
def dns_routed(): return LOCAL_DNS in sh("scutil --dns")


def read_state():
    """(vpn, dns) as the system reports them right now."""
    line = nc_line()
    if "(Connected)" not in line:
        return (False, False)
    if "Local DNS" in line:
        return (False, True)
    return (True, dns_routed())


def state_name(pair): return {(False, False): "off", (False, True): "dns", (True, False): "vpn", (True, True): "both"}[pair]
def state_pair(name): return {"off": (False, False), "dns": (False, True), "vpn": (True, False), "both": (True, True)}[name]


def is_off(): return (not nc_busy()) and (not dns_routed())


def all_off():
    """Turns everything off and returns True only once both VPN and DNS read back as off."""
    link("both/off"); link("vpn/off"); link("dns/off")
    return wait(45, is_off) is not None


def restore_to(name):
    """Restores a state and reads it back. Returns True when the system reports exactly that state."""
    target = state_pair(name)
    if name == "off":
        ok = all_off()
    else:
        all_off()
        link({"dns": "dns/on", "vpn": "vpn/on", "both": "both/on"}[name])
        ok = wait(90, lambda: read_state() == target) is not None
    final = state_name(read_state())
    print(f"Restored to {name}: system reports {final}" + ("" if ok else "  <-- NOT VERIFIED"))
    return ok


def public_ip():
    out = sh("curl -s --max-time 6 https://api.ipify.org", 10).strip()
    return out if re.fullmatch(r"[0-9a-fA-F:.]+", out or "x!") else ""


# ---- DNS ----------------------------------------------------------------------------------------------------------------------------
def dns_query(name, server=LOCAL_DNS, timeout=2.0):
    """One UDP query. Returns (milliseconds, rcode), or (None, None) on a timeout or a reply that is not for this query."""
    ident = random.randint(0, 65535)
    q = struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(timeout)
    try:
        t = time.perf_counter(); s.sendto(q, (server, 53)); data, _ = s.recvfrom(4096); ms = (time.perf_counter() - t) * 1000
        return (ms, data[3] & 0x0F) if len(data) >= 12 and struct.unpack(">H", data[:2])[0] == ident else (None, None)
    except OSError:
        return (None, None)
    finally:
        s.close()


def dns_resolves(): ms, rc = dns_query(GOOD); return ms is not None and rc == 0
def dns_blocked(): ms, rc = dns_query(BLOCKED); return ms is not None and rc == 3


def system_nameserver():
    """The first nameserver of the default resolver, which is what VPN-only DNS goes to."""
    out = sh("scutil --dns")
    m = re.search(r"resolver #1\s.*?nameserver\[0\]\s*:\s*([0-9.]+)", out, re.S)
    return m.group(1) if m else None


def pct(values, p):
    if not values: return None
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))]


def unique(domain): return "vg" + "".join(random.choices(string.ascii_lowercase + string.digits, k=12)) + "." + domain


def dns_bench(server):
    cold, warm, asked, failed, details = [], [], 0, 0, []
    for d in COLD_DOMAINS:
        n = unique(d); ms, rc = dns_query(n, server); asked += 1
        if ms is None or rc not in (0, 3): failed += 1; details.append(f"cold {n}: no usable answer")
        else: cold.append(ms)
    for n in WARM_NAMES: dns_query(n, server)                       # first sight, not measured
    for _ in range(2):
        for n in WARM_NAMES:
            ms, rc = dns_query(n, server); asked += 1
            if ms is None or rc not in (0, 3): failed += 1; details.append(f"warm {n}: no usable answer")
            else: warm.append(ms)
    return {"cold_p50_ms": pct(cold, 0.5), "cold_p95_ms": pct(cold, 0.95), "warm_p50_ms": pct(warm, 0.5),
            "success_pct": round(100.0 * (asked - failed) / asked, 2) if asked else None}, details


# ---- the tunnel process ------------------------------------------------------------------------------------------------------------
def tunnel_sample():
    pid = sh("pgrep -x VayuSetuTunnel").split()
    if not pid: return None
    out = sh(["ps", "-o", "%cpu=,rss=", "-p", pid[0]]).split()
    return (float(out[0]), float(out[1]) / 1024) if len(out) == 2 else None


def vpn_interface():
    """The utun that carries the VPN (its address is a private 10.x, unlike the DNS-only tunnel's 198.18.x)."""
    name = None
    for line in sh("ifconfig").splitlines():
        if line.startswith("utun"): name = line.split(":")[0]
        elif name and re.search(r"inet 10\.", line): return name
    return None


def all_utuns():
    return [n for n in sh("ifconfig -l").split() if n.startswith("utun")]


def iface_bytes(name):
    for line in sh(["netstat", "-ib"]).splitlines():
        f = line.split()
        # a tunnel's <Link#> row has an empty Address column, so count from the right: ... Ibytes Opkts Oerrs Obytes Coll
        if f and f[0] == name and len(f) >= 9 and "Link" in f[2]: return int(f[-5]), int(f[-2])
    return None


def ping_stats(count, interval, host="1.1.1.1"):
    out = sh(["ping", "-c", str(count), "-i", str(interval), "-q", host], count * 3 + 10)
    loss = re.search(r"([0-9.]+)% packet loss", out); rtt = re.search(r"= ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+)", out)
    return {"loss_pct": float(loss.group(1)) if loss else None, "rtt_min_ms": float(rtt.group(1)) if rtt else None,
            "rtt_avg_ms": float(rtt.group(2)) if rtt else None, "rtt_jitter_ms": float(rtt.group(4)) if rtt else None}


def top_cpu_mem(pid):
    """Instantaneous CPU % and memory MB of a process, from `top` (works for the root tunnel). None when it cannot be read."""
    out = sh(["top", "-pid", str(pid), "-l", "2", "-s", "1", "-stats", "cpu,mem"], 12).strip().splitlines()
    if not out: return None
    m = re.match(r"\s*([0-9.]+)\s+([0-9.]+)([KMG])", out[-1])
    return (float(m.group(1)), float(m.group(2)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(3)]) if m else None


def vpn_session_run(seconds):
    """One fixed-length download through the VPN with everything sampled. Returns a dict, with `valid` False when it is too short to trust."""
    pid = (sh("pgrep -x VayuSetuTunnel").split() or [None])[0]; iface = vpn_interface()
    idle = ping_stats(8, 0.2)
    before = {n: iface_bytes(n) for n in all_utuns()}
    dl = subprocess.Popen(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{size_download} %{time_total} %{num_redirects}\\n", "--max-time", str(seconds), SPEED_URL_CHUNK],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    loaded_holder = {}
    import threading
    pinger = threading.Thread(target=lambda: loaded_holder.update(ping_stats(int(seconds / 0.4) - 4, 0.4)))
    pinger.start()
    cpu, mem = [], []
    deadline = time.time() + seconds + 2          # curl's --max-time is per transfer, so the whole run is cut off here
    while dl.poll() is None and pid and time.time() < deadline:
        s_ = top_cpu_mem(pid)
        if s_: cpu.append(s_[0]); mem.append(s_[1])
    if dl.poll() is None: dl.terminate()
    out = dl.stdout.read() or ""; pinger.join()
    after = {n: iface_bytes(n) for n in before}
    moved = {n: (after[n][0] - before[n][0]) + (after[n][1] - before[n][1]) for n in before if before[n] and after.get(n)}
    if moved: iface = max(moved, key=moved.get)               # the tunnel that actually carried the download (other VPNs have utuns too)
    route_if = (re.search(r"interface:\s*(\S+)", sh("route -n get 1.1.1.1")) or [None, None])[1]
    parts = (out.split() + [None] * 4)[:4]
    try: http, size, elapsed, redirects = int(parts[0]), float(parts[1]), float(parts[2]), int(parts[3])
    except (TypeError, ValueError): http, size, elapsed, redirects = 0, 0.0, 0.0, 0
    elapsed = elapsed if elapsed > 0 else seconds                # throughput is bytes over the time the transfer really ran
    tunnel_bytes = moved.get(iface) if moved else None
    connected_end = nc_connected()
    full_window = elapsed >= seconds * 0.9                      # a 1 GB file cannot end early, so a run that did measured something else. A slow run is a real result, never discarded for being slow
    valid = len(cpu) >= 6 and http == 200 and redirects == 0 and size >= 1_000_000 and full_window and connected_end      # a run during which the tunnel is not up measured the wrong path
    return {"valid": valid, "throughput_mbps": size * 8 / elapsed / 1e6, "bytes": int(size), "cpu_samples": len(cpu),
            "cpu_avg_pct": statistics.mean(cpu) if cpu else None, "cpu_p95_pct": pct(cpu, 0.95), "cpu_max_pct": max(cpu) if cpu else None,
            "mem_max_mb": max(mem) if mem else None, "idle": idle, "loaded": dict(loaded_holder), "tunnel_bytes": tunnel_bytes, "interface": iface,
            "http": http, "elapsed_s": elapsed, "redirects": redirects, "diag": {"tunnel_pid": pid, "connected_at_end": connected_end, "route_interface": route_if, "nc": nc_line()[:60]}}


def tunnel_failure_lines_since(epoch):
    stamp = datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M:%S")
    out = sh(["/usr/bin/log", "show", "--start", stamp, "--info", "--predicate", 'subsystem == "app.vayusetu.tunnel" AND eventMessage CONTAINS " failed "', "--style", "compact"], 90)
    return [l.split("startup", 1)[-1].strip()[:140] for l in out.splitlines() if " failed " in l and not l.startswith(("Timestamp", "Filtering"))]


# ---- environment evidence ---------------------------------------------------------------------------------------------------------
def anon(value):
    """A short stable hash of something that identifies a person's setup (a VPN server, a profile or resolver name, other software). A baseline is compared
    for equality only, so a hash does the job, and a baseline can be published without naming the VPN provider, the server or the other software on the Mac."""
    if value is None or str(value).startswith("h:"): return value
    return "h:" + __import__("hashlib").sha256(("vayusetu-perf|" + str(value)).encode()).hexdigest()[:10]

def anonymise(env):
    """The environment of a run with everything that identifies the setup replaced by hashes; the kind of connection and the commit stay readable."""
    env = dict(env or {})
    ext = env.get("extensions_active") or []
    env["extensions_active"] = [l for l in ext if "app.vayusetu" in l]                       # VayuSetu's own extensions, with their versions
    env["other_extensions_active"] = [anon(l) for l in env.get("other_extensions_active") or []]
    for key in ("vpn_profile", "vpn_endpoint_host", "vpnonly_nameserver"): env[key] = anon(env.get(key))
    env["dns_resolvers_configured"] = [anon(n) for n in env.get("dns_resolvers_configured") or []]
    env["other_vpn_connected"] = [anon(l) for l in env.get("other_vpn_connected") or []]
    return env

def environment():
    return anonymise(raw_environment())

def sanitize_result(result):
    """A saved result made safe to publish: the environment is hashed, and any other place a name from that setup appears (the evidence and notes) is
    replaced by the same hash, found by looking for the raw values the environment held. Returns how many places were changed."""
    env = result.get("environment") or {}
    raw = []
    for key in ("vpn_profile", "vpn_endpoint_host", "vpnonly_nameserver"): raw.append(env.get(key))
    raw += list(env.get("dns_resolvers_configured") or []) + list(env.get("other_vpn_connected") or [])
    for line in (env.get("extensions_active") or []) + (env.get("other_extensions_active") or []):
        if "app.vayusetu" not in line:
            raw.append(line)
            for part in re.findall(r"(?:com|org|net)\.[A-Za-z0-9.-]+", line): raw.append(part)
    raw = sorted({r for r in raw if r and not str(r).startswith("h:")}, key=len, reverse=True)
    changed = 0
    def scrub(node):
        nonlocal changed
        if isinstance(node, str):
            out = node
            for r in raw:
                if r in out: out = out.replace(r, anon(r)); changed += 1
            return out
        if isinstance(node, list): return [scrub(x) for x in node]
        if isinstance(node, dict): return {k: scrub(v) for k, v in node.items()}
        return node
    result = scrub(result)
    result["environment"] = anonymise(result.get("environment"))
    return result, changed

def sanitize_cmd(a):
    data = json.load(open(a.file))
    data, changed = sanitize_result(data)
    txt = json.dumps(data)
    leftovers = [w for w in ("surfshark", "adguard", "lulu", "nordvpn", "expressvpn", "tailscale", "objective-see") if w in txt.lower()]
    json.dump(data, open(a.file, "w"), indent=2, sort_keys=True); open(a.file, "a").write("\n")
    print(f"{a.file}: {changed} value(s) replaced by hashes" + (f"; STILL NAMES {leftovers}" if leftovers else "; no third-party names remain"))
    sys.exit(1 if leftovers else 0)

def raw_environment():
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    commit = sh(["git", "-C", repo, "rev-parse", "--short", "HEAD"]).strip()
    dirty = [l for l in sh(["git", "-C", repo, "status", "--short"]).splitlines() if l.strip()]
    ext = [re.sub(r"\s+", " ", l.strip()) for l in sh("systemextensionsctl list").splitlines() if "[activated enabled]" in l]
    others = [l for l in ext if "app.vayusetu" not in l]
    support = os.path.expanduser("~/Library/Application Support/VayuSetuVPN")
    vpn_name, endpoint, resolvers = None, None, []
    m = re.search(r'"VayuSetu · ([^"]+)"', nc_line())
    if m and m.group(1) != "Local DNS": vpn_name = m.group(1)
    try:
        profiles = json.load(open(os.path.join(support, "profiles.json"))).get("profiles", [])
        match = [p for p in profiles if p.get("name") == vpn_name]
        endpoint = (match[0].get("endpoints") or [None])[0] if match else None
        endpoint = endpoint.rsplit(":", 1)[0] if endpoint else None          # the host only, never a key or a full config
    except Exception: pass
    try:
        resolvers = [p.get("name") for p in json.load(open(os.path.join(support, "dns-profiles.json"))).get("profiles", [])]
    except Exception: pass
    route = sh("route -n get default")
    iface = (re.search(r"interface:\s*(\S+)", route) or [None, None])[1]
    kind = None
    if iface:
        for block in sh("networksetup -listallhardwareports").split("Hardware Port:")[1:]:
            if f"Device: {iface}" in block: kind = block.splitlines()[0].strip()
    return {"git_commit": commit, "git_dirty_files": len(dirty), "git_dirty_sample": dirty[:6],
            "extensions_active": ext, "other_extensions_active": others, "vpn_profile": vpn_name, "vpn_endpoint_host": endpoint,
            "dns_resolvers_configured": resolvers, "default_interface": iface, "network_kind": kind,
            "other_vpn_connected": [l.strip()[:90] for l in sh("scutil --nc list").splitlines() if "(Connected)" in l and "app.vayusetu" not in l],
            "cold_method": "random label under a real domain; either an answer or no-such-name counts as success"}


# ---- measurement -------------------------------------------------------------------------------------------------------------------
class Interrupted(Exception): pass


def on_signal(signum, _frame):
    raise Interrupted(signal.Signals(signum).name)


def timed_connect(kind, base_ip):
    """(seconds, None) when the thing the mode promises became true, else (None, reason)."""
    if not all_off(): return None, "could not turn everything off first"
    t0 = time.time()
    link({"dns": "dns/on", "vpn": "vpn/on", "both": "both/on"}[kind])
    if wait(60, nc_connected) is None: return None, "the tunnel did not report connected within 60 s"
    if kind in ("dns", "both"):
        if wait(60, dns_resolves) is None: return None, "a normal name did not resolve through the tunnel within 60 s"
        if wait(60, dns_blocked) is None: return None, "a blocked name was not blocked within 60 s"
    if kind in ("vpn", "both") and wait(60, lambda: public_ip() not in ("", base_ip)) is None: return None, "the public address did not change within 60 s"
    return time.time() - t0, None


def measure(args):
    if not sh("pgrep -x VayuSetuVPN").strip(): sys.exit("VayuSetu is not running. Open /Applications/VayuSetu.app first.")
    os.makedirs(PERF, exist_ok=True)
    original = state_name(read_state())
    json.dump({"state": original, "started": now_iso(), "pid": os.getpid()}, open(RESTORE_FILE, "w"))
    print(f"Starting state: {original} (saved to {os.path.abspath(RESTORE_FILE)}; `perf_gate.py restore` puts it back if this is interrupted)")
    signal.signal(signal.SIGINT, on_signal); signal.signal(signal.SIGTERM, on_signal); signal.signal(signal.SIGHUP, on_signal)
    result, problem = None, None
    start = time.time()
    try:
        result = run_measurements(args, start)
    except Interrupted as e:
        problem = f"interrupted by {e}"
    except BaseException as e:                              # an unexpected error must not leave protection off
        problem = f"{type(e).__name__}: {e}"
    finally:
        signal.signal(signal.SIGINT, signal.SIG_IGN)            # nothing may cut the restore short
        print("\nRestoring the starting state…")
        verified = restore_to(original)
        if verified and os.path.exists(RESTORE_FILE): os.remove(RESTORE_FILE)
    if result is not None:
        result["restore_verified"] = verified; result["ended"] = now_iso()
        out = args.out or os.path.join(PERF, f"build-{result['build']}.json")
        json.dump(result, open(out, "w"), indent=2, sort_keys=True)
        print(f"\nSaved {os.path.abspath(out)}"); show_dict(result)
    if problem: print(f"\nThe run did not finish: {problem}. No result file was written.")
    if not verified: print("\nWARNING: the starting state could not be verified. Run `perf_gate.py restore`."); sys.exit(3)
    if problem: sys.exit(2)


def run_measurements(args, start):
    started = now_iso()
    if not all_off(): raise RuntimeError("could not turn VayuSetu protection off before starting, so the first figures would be contaminated")
    others = [l.strip()[:90] for l in sh("scutil --nc list").splitlines() if "(Connected)" in l and "app.vayusetu" not in l]
    if others and not args.allow_other_vpn: raise RuntimeError(f"another VPN is connected ({others[0]}); disconnect it, or pass --allow-other-vpn to record the run as shared")
    base_ip = public_ip()
    if not base_ip: raise RuntimeError("no internet, so nothing can be measured")
    metrics, runs_detail, notes = {}, {}, []
    build = sh("/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/VayuSetu.app/Contents/Info.plist").strip()
    runs = args.runs

    def series(key, fn):
        values, detail = [], []
        for i in range(runs):
            v, why = fn()
            print(f"  {key} run {i + 1}: " + (f"{v:.2f}" if v is not None else f"failed — {why}"))
            detail.append({"run": i + 1, "seconds": v, "failure": why})
            if v is not None: values.append(v)
        metrics[key] = statistics.median(values) if values else None
        runs_detail[key] = detail
        if len(values) < runs: notes.append(f"{key}: {runs - len(values)} of {runs} runs failed")

    print("Warm-up (not measured): bringing everything up once, so a tunnel replaced by an install is not timed")
    link("both/on")
    if wait(120, nc_connected) is None or wait(60, dns_blocked) is None: raise RuntimeError("warm-up: VPN + DNS did not come up, so the figures would not mean anything")
    if not all_off(): raise RuntimeError("warm-up: could not turn protection off again")
    env = environment()          # read once the tunnel has been replaced if it was going to be

    print("Connect times")
    series("connect_dns_s", lambda: timed_connect("dns", base_ip)); series("connect_vpn_s", lambda: timed_connect("vpn", base_ip)); series("connect_both_s", lambda: timed_connect("both", base_ip))

    print("Switching DNS only to VPN + DNS")
    def switch():
        if not all_off(): return None, "could not turn everything off first"
        link("dns/on")
        if wait(60, lambda: nc_connected() and dns_resolves()) is None: return None, "DNS-only did not come up"
        t0 = time.time(); link("vpn/on")
        if wait(90, lambda: nc_connected() and public_ip() not in ("", base_ip) and dns_blocked()) is None: return None, "VPN + DNS did not come up within 90 s"
        return time.time() - t0, None
    series("switch_dns_to_both_s", switch)

    print("Stop time")
    def stop():
        link("dns/on")
        if wait(60, nc_connected) is None: return None, "DNS-only did not come up"
        t0 = time.time(); link("both/off"); link("dns/off")
        return (time.time() - t0, None) if wait(45, is_off) is not None else (None, "did not read back as off within 45 s")
    series("stop_s", stop)

    for mode in DNS_MODES:
        print(f"DNS in {mode} mode")
        if not all_off(): raise RuntimeError(f"could not turn protection off before the {mode} DNS measurements, so they would be contaminated")
        link({"dnsonly": "dns/on", "both": "both/on", "vpnonly": "vpn/on"}[mode])
        if wait(60, nc_connected) is None: notes.append(f"dns {mode}: the tunnel did not connect"); continue
        server = LOCAL_DNS if mode != "vpnonly" else None
        if mode != "vpnonly": wait(60, dns_blocked)
        else:
            wait(60, lambda: public_ip() not in ("", base_ip)); time.sleep(2); server = system_nameserver()
            if not server: notes.append("dns vpnonly: no system nameserver found"); continue
            env["vpnonly_nameserver"] = anon(server)
        time.sleep(2)
        r, details = dns_bench(server)
        for k, v in r.items(): metrics[f"dns_{mode}_{k}" if mode != "vpnonly" else f"diag_dns_vpnonly_{k}"] = v
        runs_detail[f"dns_{mode}"] = details[:20]
        print("  " + ", ".join(f"{k}={v:.1f}" if isinstance(v, float) else f"{k}={v}" for k, v in r.items()))

    print(f"VPN: {args.vpn_runs} fixed-length downloads ({args.vpn_seconds} s each), sampled once a second")
    if not all_off(): raise RuntimeError("could not turn protection off before the VPN download phase")
    link("both/on")
    up = wait(60, nc_connected) is not None and wait(60, lambda: public_ip() not in ("", base_ip)) is not None and wait(60, dns_blocked) is not None
    if not up: notes.append("vpn: the tunnel did not come up for the download phase, so no VPN figures were recorded")
    time.sleep(3)
    runs_v = []
    for i in range(args.vpn_runs if up else 0):
        ensure_app()
        if not nc_connected():
            print("  the tunnel was down before this run; bringing it back"); link("both/on"); wait(60, nc_connected); time.sleep(3)
        r = vpn_session_run(args.vpn_seconds); runs_v.append(r)
        print(f"  run {i + 1}: {r['throughput_mbps']:.2f} Mbit/s, cpu avg {r['cpu_avg_pct'] or 0:.0f}% p95 {r['cpu_p95_pct'] or 0:.0f}%, "
              f"rtt idle {r['idle']['rtt_avg_ms']} loaded {r['loaded'].get('rtt_avg_ms')} ms, loss {r['loaded'].get('loss_pct')}%, "
              f"{r['cpu_samples']} cpu samples" + ("" if r["valid"] else f"  <-- FLAGGED, left out (http {r['http']}, {r['bytes'] / 1e6:.1f} MB in {r['elapsed_s']:.1f} s, connected at end: {r['diag']['connected_at_end']})"))
        time.sleep(2)
    good = [r for r in runs_v if r["valid"]]
    if len(good) < len(runs_v): notes.append(f"vpn: {len(runs_v) - len(good)} of {len(runs_v)} downloads were too short or sampled too little to trust")
    need = max(4, -(-args.vpn_runs * 6 // 10))                       # at least 60% of the runs, and never fewer than 4
    metrics["vpn_valid_runs"] = len(good)
    if len(good) < need:
        if runs_v: notes.append(f"vpn: only {len(good)} of {args.vpn_runs} runs were valid (need {need}); no VPN throughput or CPU figures are recorded, so none can be used to pass or fail a change")
        good = []
    if good:
        metrics["vpn_throughput_mbps"] = statistics.median(r["throughput_mbps"] for r in good)
        metrics["vpn_cpu_avg_pct"] = statistics.median(r["cpu_avg_pct"] for r in good)
        metrics["vpn_cpu_p95_pct"] = statistics.median(r["cpu_p95_pct"] for r in good)
        metrics["vpn_cpu_max_pct"] = max(r["cpu_max_pct"] for r in good)
        metrics["tunnel_mem_mb"] = max(r["mem_max_mb"] for r in good)
        metrics["vpn_rtt_idle_ms"] = statistics.median(r["idle"]["rtt_avg_ms"] for r in good if r["idle"]["rtt_avg_ms"] is not None)
        loaded = [r["loaded"] for r in good if r["loaded"].get("rtt_avg_ms") is not None]
        metrics["vpn_rtt_loaded_ms"] = statistics.median(x["rtt_avg_ms"] for x in loaded) if loaded else None
        metrics["vpn_loss_pct"] = statistics.mean(x["loss_pct"] for x in loaded) if loaded else None
        metrics["vpn_tunnel_mb"] = statistics.median(r["tunnel_bytes"] for r in good if r["tunnel_bytes"]) / 1e6 if any(r["tunnel_bytes"] for r in good) else None
        metrics["vpn_throughput_spread_mbps"] = max(r["throughput_mbps"] for r in good) - min(r["throughput_mbps"] for r in good)
        metrics["vpn_cpu_avg_spread_pct"] = max(r["cpu_avg_pct"] for r in good) - min(r["cpu_avg_pct"] for r in good)
    runs_detail["vpn_runs"] = runs_v
    print(f"  median throughput {metrics.get('vpn_throughput_mbps')} Mbit/s, cpu avg {metrics.get('vpn_cpu_avg_pct')}% p95 {metrics.get('vpn_cpu_p95_pct')}%, "
          f"rtt {metrics.get('vpn_rtt_idle_ms')} ms, loss {metrics.get('vpn_loss_pct')}%")

    if args.flap:
        print("Wi-Fi flap: off for 5 seconds, then time the recovery")
        iface = (sh("networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}'").strip() or "en0")
        try:
            sh(["networksetup", "-setairportpower", iface, "off"]); time.sleep(5)
        finally:
            sh(["networksetup", "-setairportpower", iface, "on"])              # Wi-Fi is switched back on even if interrupted
        t0 = time.time()
        rec = wait(120, lambda: nc_connected() and public_ip() not in ("", base_ip) and dns_resolves())
        metrics["flap_recover_s"] = (time.time() - t0) if rec is not None else None
        print(f"  recovered in {metrics['flap_recover_s']}")

    failures = tunnel_failure_lines_since(start)
    metrics["tunnel_failures"] = len(failures); metrics["app_exits"] = APP_EXITS
    runs_detail["tunnel_failure_lines"] = failures[:20]
    return {"schema": SCHEMA, "provisional": False, "build": build, "date": now_iso(), "started": started, "runs": runs, "flap": bool(args.flap), "sessions": 1, "vpn_seconds": args.vpn_seconds,
            "host": sh("sysctl -n hw.model").strip(), "os": sh("sw_vers -productVersion").strip(), "environment": env,
            "metrics": metrics, "evidence": runs_detail, "notes": notes + ["battery: not measured on the Mac"]}


# ---- restore, show, compare ----------------------------------------------------------------------------------------------------------
def restore_cmd(args):
    target = args.to
    if not target:
        try: target = json.load(open(RESTORE_FILE))["state"]
        except Exception: sys.exit("There is no saved starting state. Say which state to restore: restore --to off|dns|vpn|both")
    ok = restore_to(target)
    if ok and os.path.exists(RESTORE_FILE): os.remove(RESTORE_FILE)
    sys.exit(0 if ok else 3)


def merge_cmd(args):
    files = [json.load(open(f)) for f in args.files]
    builds = {f["build"] for f in files}
    if len(builds) != 1: sys.exit(f"These files are from different builds ({sorted(builds)}); merge only sessions of one build.")
    keys = sorted({k for f in files for k in f["metrics"] if not k.endswith("_all")})
    metrics, spread = {}, {}
    for k in keys:
        vals = [f["metrics"].get(k) for f in files if isinstance(f["metrics"].get(k), (int, float))]
        if not vals: metrics[k] = None; continue
        metrics[k] = statistics.median(vals); spread[k] = max(vals) - min(vals)
    merged = dict(files[0]); merged.update({"metrics": metrics, "spread": spread, "sessions": len(files), "merged_from": [os.path.basename(f) for f in args.files],
                                           "date": now_iso(), "provisional": len(files) < 2, "restore_verified": all(f.get("restore_verified", True) for f in files)})
    merged["environment"] = files[-1].get("environment")
    json.dump(merged, open(args.out, "w"), indent=2, sort_keys=True)
    print(f"Merged {len(files)} sessions of build {files[0]['build']} into {args.out}")
    for k in ("vpn_throughput_mbps", "vpn_cpu_avg_pct", "vpn_cpu_p95_pct", "vpn_rtt_idle_ms", "vpn_loss_pct"):
        if k in metrics and metrics[k] is not None: print(f"  {k:24} median {metrics[k]:.2f}   spread across sessions {spread.get(k, 0):.2f}")


def show_dict(r):
    print(f"Build {r['build']} · {r['date']} · {r.get('host')} · macOS {r.get('os')} · {r['runs']} runs · schema {r.get('schema', 1)}" + (" · PROVISIONAL" if r.get("provisional") else ""))
    env = r.get("environment") or {}
    if env: print(f"  commit {env.get('git_commit')} ({env.get('git_dirty_files')} uncommitted) · {env.get('network_kind')} {env.get('default_interface')} · vpn {env.get('vpn_profile')} → {env.get('vpn_endpoint_host')}")
    for k, v in sorted(r["metrics"].items()):
        print(f"  {k:30} {'—' if v is None else (f'{v:.2f}' if isinstance(v, float) else v)}")
    for n in r.get("notes", []): print("  note:", n)
    if "restore_verified" in r: print("  restore verified:", r["restore_verified"])


def compare(baseline, current):
    b, c = json.load(open(baseline)), json.load(open(current))
    print(f"Baseline build {b['build']} ({b['date']}, {b.get('sessions', 1)} session(s))   Current build {c['build']} ({c['date']})")
    warnings = []
    if b.get("schema", 1) != c.get("schema", 1) or c.get("schema", 1) != SCHEMA:
        print(f"\nREFUSED: the files come from different gate versions (baseline schema {b.get('schema', 1)}, current schema {c.get('schema', 1)}, this gate {SCHEMA}). "
              "Their figures are not comparable. Regenerate the baseline with this gate (two sessions, then `merge`).")
        return 2
    for label, d in (("baseline", b), ("current", c)):
        if d.get("schema", 1) < SCHEMA: warnings.append(f"the {label} file is from an older gate (schema {d.get('schema', 1)}); its figures are not comparable")
        if d.get("provisional") and label == "baseline": warnings.append("the baseline is marked provisional (one session)")
        if d.get("restore_verified") is False: warnings.append(f"the {label} run could not verify that protection was restored")
    # The tunnel's memory is a high-water mark that follows throughput (about 80 MB when idle, 170 MB or more after a 100 Mbit/s burst), so a
    # fast run in one session and none in the other is not a regression. Memory is therefore compared at normal load: the runs before the first
    # one above NORMAL_LOAD_MBPS. The peak is still reported, and a hard ceiling applies to it.
    def memory_view(d, base_dir=None):
        def normal(runs):
            ok = [r for r in runs if r.get("valid") and r.get("mem_max_mb") is not None]
            cut = next((i for i, r in enumerate(ok) if r["throughput_mbps"] > NORMAL_LOAD_MBPS), len(ok))
            vals = [r["mem_max_mb"] for r in ok[:cut]]
            return statistics.median(vals) if vals else None, max((r["mem_max_mb"] for r in ok), default=None)
        files = [os.path.join(base_dir, n) for n in d.get("merged_from", [])] if base_dir else []
        runs_sets = [json.load(open(f)).get("evidence", {}).get("vpn_runs", []) for f in files if os.path.exists(f)] or [d.get("evidence", {}).get("vpn_runs", [])]
        pairs = [normal(rs) for rs in runs_sets if rs]
        norm = [x[0] for x in pairs if x[0] is not None]; peak = [x[1] for x in pairs if x[1] is not None]
        return (statistics.median(norm) if norm else None), (max(peak) if peak else None)
    mem_b, peak_b = memory_view(b, os.path.dirname(os.path.abspath(baseline)))
    mem_c, peak_c = memory_view(c)
    if mem_b is not None and mem_c is not None:
        b["metrics"]["tunnel_mem_mb"], c["metrics"]["tunnel_mem_mb"] = mem_b, mem_c
        print(f"Tunnel memory is compared at normal load (runs up to {NORMAL_LOAD_MBPS:.0f} Mbit/s): baseline {mem_b:.0f} MB, current {mem_c:.0f} MB. Peak: baseline {peak_b:.0f} MB, current {peak_c:.0f} MB.")
    if peak_c is not None and peak_c > MEMORY_CEILING_MB: warnings.append(f"the tunnel's peak memory was {peak_c:.0f} MB, above the {MEMORY_CEILING_MB} MB ceiling")
    be, ce = b.get("environment") or {}, c.get("environment") or {}
    # A result measured on uncommitted source cannot be tied to one commit, so a comparison against it is only as good as the working tree was.
    for label, env in (("baseline", be), ("current run", ce)):
        if env.get("git_dirty_files"): warnings.append(f"the {label} was measured with {env['git_dirty_files']} uncommitted change(s) (commit {env.get('git_commit')}), so it cannot be tied to one commit")
    for key, what in (("vpn_endpoint_host", "VPN endpoint"), ("network_kind", "network type"), ("default_interface", "interface"), ("vpn_profile", "VPN profile")):
        if be.get(key) != ce.get(key): warnings.append(f"{what} differs ({be.get(key)} vs {ce.get(key)})")
    if sorted(be.get("other_extensions_active", [])) != sorted(ce.get("other_extensions_active", [])): warnings.append("other VPN or filter extensions were active in one run and not the other")
    # Are the two runs on the same path? The round-trip time through the VPN is the fingerprint (the server address cannot be read without admin rights).
    rb, rc = b["metrics"].get("vpn_rtt_idle_ms"), c["metrics"].get("vpn_rtt_idle_ms")
    same_path = rb is not None and rc is not None and abs(rb - rc) <= max(15.0, 0.2 * rb)
    blocking_sensitive = b.get("sessions", 1) >= 2 and same_path
    if not same_path: warnings.append(f"the round-trip times through the VPN differ ({rb} vs {rc} ms): a different server or path, so throughput and CPU are advisory only")
    elif b.get("sessions", 1) < 2: warnings.append("the baseline is from a single session: throughput and CPU are advisory only until a second session is merged in")
    for w in warnings: print("WARNING:", w)
    spread = b.get("spread", {})
    print(f"\n{'metric':30} {'baseline':>10} {'current':>10} {'change':>9}  verdict")
    worse = 0
    for key, (direction, rel, absolute) in LIMITS.items():
        old, new = b["metrics"].get(key), c["metrics"].get(key)
        if old is None and new is None: continue
        advisory = key in SENSITIVE and not blocking_sensitive
        absolute = max(absolute, spread.get(key, 0.0))                  # never call noise a regression: widen by what two sessions actually differed by
        if new is None: verdict, change, bad = "WORSE (not measured)", "—", True
        elif old is None: verdict, change, bad = "new", "—", False
        else:
            delta = new - old; change = f"{(delta / old * 100):+.0f}%" if old else f"{delta:+.1f}"
            bad = (delta > 0 and delta > absolute and delta > abs(old) * rel) if direction == "lower" else (delta < 0 and -delta > absolute and -delta > abs(old) * rel)
            good = (delta < 0 and -delta > absolute) if direction == "lower" else (delta > 0 and delta > absolute)
            verdict = "WORSE" if bad else ("better" if good else "same")
        if advisory and bad: verdict += " (advisory)"; bad = False
        worse += bad
        fmt = lambda v: "—" if v is None else f"{v:.1f}"
        print(f"{key:30} {fmt(old):>10} {fmt(new):>10} {change:>9}  {verdict}")
    diag = sorted(k for k in c["metrics"] if k.startswith("diag_"))
    if diag:
        print("\nDiagnostics (provider quality, never blocking):")
        for k in diag: print(f"  {k:36} baseline {b['metrics'].get(k)}  current {c['metrics'].get(k)}")
    print("\n" + (f"GATE FAILED: {worse} metric(s) worse than the baseline beyond the allowed margin. Keep the previous version." if worse
                  else "GATE PASSED: nothing blocking is worse than the baseline beyond the allowed margins." + (" (see the warnings)" if warnings else "")))
    return 1 if worse else 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("measure"); m.add_argument("--runs", type=int, default=3); m.add_argument("--out"); m.add_argument("--flap", action="store_true"); m.add_argument("--vpn-runs", type=int, default=5); m.add_argument("--vpn-seconds", type=int, default=15); m.add_argument("--allow-other-vpn", action="store_true")
    c = sub.add_parser("compare"); c.add_argument("baseline"); c.add_argument("current")
    s = sub.add_parser("show"); s.add_argument("file")
    g = sub.add_parser("merge"); g.add_argument("out"); g.add_argument("files", nargs="+")
    z = sub.add_parser("sanitize", help="replace what identifies the setup in a saved result with hashes, in place"); z.add_argument("file")
    r = sub.add_parser("restore"); r.add_argument("--to", choices=["off", "dns", "vpn", "both"])
    a = p.parse_args()
    if a.cmd == "measure": measure(a)
    elif a.cmd == "compare": sys.exit(compare(a.baseline, a.current))
    elif a.cmd == "restore": restore_cmd(a)
    elif a.cmd == "merge": merge_cmd(a)
    elif a.cmd == "sanitize": sanitize_cmd(a)
    else: show_dict(json.load(open(a.file)))


if __name__ == "__main__":
    main()
