#!/bin/bash
# The Mac release, in one command: build, sign with Developer ID, notarize, staple, then verify the result.
#
#   macos/scripts/release/release.sh --check     # preflight only: proves the machine can release, builds nothing
#   macos/scripts/release/release.sh             # the whole release
#   macos/scripts/release/release.sh --verify-only <dmg>
#   macos/scripts/release/release.sh --allow-dirty    # for a local trial only: the result is marked dirty and verification will not clear it
#
# A release is built from a CLEAN, COMMITTED tree. Next to the disk image it writes <dmg>.source.json (the commit, the tree, the tool versions, the hash of
# the image), and after verification it tags that commit mac-<version>-<build>. A tree with uncommitted changes is refused, because the artifact could then
# not be reproduced or tied to anything.
#
# Nothing machine-specific lives in this file. The checkout is found from the script's own location; the version and the disk image name come from
# macos/scripts/version.json; notarization credentials come from the environment or from an untracked file (see below). It stops at the first failure
# and says which step failed; it never reports success for a step that did not finish.
#
# Notarization credentials, either of:
#   VAYU_NOTARY_PROFILE                      a notarytool Keychain profile (xcrun notarytool store-credentials)
#   VAYU_ASC_API_KEY_PATH, VAYU_ASC_API_KEY_ID, VAYU_ASC_ISSUER_ID     an App Store Connect API key
# They are read from the environment, or from the file named by VAYU_RELEASE_ENV (default ~/.config/vayusetu/release.env), which is outside the repository
# and should be readable only by you (chmod 600). Identifiers and key paths are never written to the repository or to the logs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"      # repository root
mac="$root/macos"
cd "$mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

mode=release; verify_dmg=""; allow_dirty=0
case "${1:-}" in
    --check) mode=check;;
    --allow-dirty) allow_dirty=1;;
    --verify-only) mode=verify; verify_dmg="${2:?pass the disk image to verify}";;
    "" ) ;;
    *) echo "Unknown option: $1 (use --check, --verify-only <dmg>, or no option)" >&2; exit 64;;
esac

env_file="${VAYU_RELEASE_ENV:-$HOME/.config/vayusetu/release.env}"
if [[ -f "$env_file" ]]; then
    perms="$(stat -f '%Lp' "$env_file")"
    [[ "$perms" == "600" || "$perms" == "400" ]] || { echo "Refusing to read $env_file: its permissions are $perms. Run: chmod 600 \"$env_file\"" >&2; exit 78; }
    set -a; . "$env_file"; set +a
fi

version_file="scripts/version.json"
field() { python3 -c "import json,sys; print(json.load(open('$version_file'))[sys.argv[1]])" "$1"; }
marketing="$(field marketing)"; build="$(field build)"
dmg="dist/release/VayuSetu-$marketing-$build-macOS.dmg"
logs="build/release-logs/$build"; status="build/release-status.txt"
mkdir -p "$logs" build/release

fail() { echo "FAIL  $*" >&2; exit 1; }
ok()   { echo "OK    $*"; }

# ---- preflight (also the whole of --check) ---------------------------------------------------------------------------------------------------
preflight() {
    local problems=0
    bad() { echo "MISSING $*" >&2; problems=$((problems+1)); }
    [[ -d "$DEVELOPER_DIR" ]] || bad "full Xcode at $DEVELOPER_DIR"
    [[ -x "$DEVELOPER_DIR/usr/bin/notarytool" || -n "$(xcrun --find notarytool 2>/dev/null || true)" ]] || bad "notarytool (part of full Xcode)"
    security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" || bad "a 'Developer ID Application' signing identity in the keychain"
    if [[ -n "${VAYU_NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool history --keychain-profile "$VAYU_NOTARY_PROFILE" >/dev/null 2>&1 || bad "the notarytool Keychain profile '$VAYU_NOTARY_PROFILE' (does not work)"
    elif [[ -n "${VAYU_ASC_API_KEY_PATH:-}" ]]; then
        [[ -f "$VAYU_ASC_API_KEY_PATH" ]] || bad "the App Store Connect key file named by VAYU_ASC_API_KEY_PATH"
        [[ -n "${VAYU_ASC_API_KEY_ID:-}" ]] || bad "VAYU_ASC_API_KEY_ID"
        [[ -n "${VAYU_ASC_ISSUER_ID:-}" ]] || bad "VAYU_ASC_ISSUER_ID"
    else
        bad "notarization credentials: set VAYU_NOTARY_PROFILE, or VAYU_ASC_API_KEY_PATH + VAYU_ASC_API_KEY_ID + VAYU_ASC_ISSUER_ID (in the environment or $env_file)"
    fi
    for f in scripts/build-vpn.sh scripts/release/sign-devid.sh scripts/release/notarize.sh tools/verify-release.sh tools/check-versions.py "$version_file"; do [[ -f "$f" ]] || bad "$f"; done
    [[ -f "$root/ios/build/patched-go/.prepared" ]] || bad "the prepared Go runtime (build the iOS extension once, see build-vpn.sh)"
    python3 tools/check-versions.py >/dev/null || bad "consistent versions (run macos/tools/check-versions.py)"
    local free_kb; free_kb="$(df -k . | awk 'NR==2{print $4}')"
    [[ "$free_kb" -gt 5000000 ]] || bad "5 GB of free disk space (have $((free_kb/1048576)) GB)"
    if [[ -e "$dmg" ]]; then echo "NOTE  $dmg already exists and will be replaced" >&2; fi
    pgrep -f "scripts/build-vpn.sh" >/dev/null && bad "no other build running (build-vpn.sh is running)"
    local changes; changes="$(cd "$root" && git status --porcelain | wc -l | tr -d ' ')"
    if [[ "$changes" != "0" ]]; then
        if [[ $allow_dirty -eq 1 ]]; then echo "NOTE  $changes uncommitted change(s): this build will be marked dirty and cannot be cleared for release" >&2
        else bad "a clean committed tree ($changes uncommitted or untracked change(s)); commit them, or use --allow-dirty for a local trial that cannot be released"; fi
    fi
    if [[ -z "$(cd "$root" && git rev-parse --verify HEAD 2>/dev/null)" ]]; then bad "a git commit to build from"; fi
    if (cd "$root" && git rev-parse --verify "refs/tags/mac-$marketing-$build" >/dev/null 2>&1); then bad "an unused build number: tag mac-$marketing-$build already exists, so build $build was released before (raise the build in $version_file)"; fi
    [[ $problems -eq 0 ]]
}

if [[ "$mode" == check ]]; then
    preflight && { ok "this machine can release build $build ($marketing): $dmg"; exit 0; }
    fail "preflight found problems (listed above); nothing was built"
fi

if [[ "$mode" == verify ]]; then exec bash tools/verify-release.sh "$verify_dmg"; fi

# ---- the release ------------------------------------------------------------------------------------------------------------------------------
preflight || fail "preflight found problems (listed above); nothing was built"
lock="build/release.lock"
mkdir "$lock" 2>/dev/null || fail "another release is running (remove $lock if it is not)"
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
: > "$status"
step() { # step <name> <command...>: runs one stage, logs it, records "name 0" or stops
    local name="$1"; shift
    echo "==> $name"
    if "$@" > "$logs/$name.log" 2>&1; then echo "$name 0" >> "$status"; ok "$name"
    else local rc=$?; echo "$name $rc" >> "$status"; tail -15 "$logs/$name.log" >&2; fail "$name failed (exit $rc); full log: $mac/$logs/$name.log"; fi
}

step vpn      bash scripts/build-vpn.sh
step sign     bash scripts/release/sign-devid.sh
[[ -f "$dmg" ]] || fail "signing finished but $dmg was not produced (the name comes from $version_file)"
step notarize bash scripts/release/notarize.sh "$dmg"
echo "done" >> "$status"

# What this artifact was built from, written beside it so anyone can check that a disk image and a commit belong together.
python3 - "$dmg" "$root" "$allow_dirty" <<'PY'
import hashlib, json, subprocess, sys, platform
from datetime import datetime, timezone
dmg, root, allow = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
def run(*a):
    r = subprocess.run(a, capture_output=True, text=True); return (r.stdout or r.stderr).strip()
def git(*a): return run("git", "-C", root, *a)
version = json.load(open("scripts/version.json"))
record = {
    "artifact": dmg.split("/")[-1], "sha256": hashlib.sha256(open(dmg, "rb").read()).hexdigest(),
    "commit": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"), "subject": git("log", "-1", "--format=%s"),
    "dirty": bool(git("status", "--porcelain")), "allowDirty": allow, "version": version,
    "built": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "tools": {"xcode": run("xcodebuild", "-version").replace("\n", " "), "swift": run("swift", "--version").splitlines()[0], "macOS": platform.mac_ver()[0],
              "go": run(root + "/ios/build/patched-go/bin/go", "version"), "machine": platform.machine()},
}
open(dmg + ".source.json", "w").write(json.dumps(record, indent=2) + "\n")
print("source record:", dmg + ".source.json", "commit", record["commit"][:10], "dirty" if record["dirty"] else "clean")
PY

echo "==> verify"
bash tools/verify-release.sh "$dmg" || { rc=$?; fail "verification did not pass (exit $rc); the disk image is built but is NOT cleared for release"; }
ok "build $build ($marketing) is built, signed, notarized, stapled and verified: $dmg"
if [[ $allow_dirty -eq 1 ]] || [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    echo "NOT TAGGED  the tree was not clean, so this image cannot be tied to one commit and is not a release candidate" >&2; exit 3
fi
git -C "$root" tag -a "mac-$marketing-$build" -m "VayuSetu for Mac $marketing (build $build)" && ok "tagged mac-$marketing-$build at $(git -C "$root" rev-parse --short HEAD)"
