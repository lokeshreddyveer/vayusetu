#!/usr/bin/python3
"""Rebuild/install the free-signing preview; opt-in per-user launchd scheduling."""
import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "renewal"
STATE = BUILD / "state.json"
LABEL = "app.vayusetu.ios.renewal"
AGENT = Path.home() / "Library" / "LaunchAgents" / (LABEL + ".plist")
DEVICE = os.environ.get("VAYU_DEVICE", "")  # the device identifier from `xcrun devicectl list devices`
TEAM = "X4MH29QNRS"
BUNDLE = "app.vayusetu.ios.preview"
XCODE = "/Applications/Xcode.app/Contents/Developer"
APP = BUILD / "DerivedData/Build/Products/Debug-iphoneos/VayuSetu.app"
UTC = dt.timezone.utc


def now():
    return dt.datetime.now(UTC)


def parse_date(value):
    return dt.datetime.fromisoformat(value).astimezone(UTC)


def read_state():
    if not STATE.exists():
        return {}
    value = json.loads(STATE.read_text())
    if not isinstance(value, dict):
        raise ValueError("Invalid renewal state; inspect build/renewal/state.json.")
    return value


def save_state(state):
    # Atomic replacement preserves the last installed expiry on failed attempts.
    with tempfile.NamedTemporaryFile(mode="w", dir=BUILD, delete=False) as handle:
        json.dump(state, handle, indent=2)
        temporary = Path(handle.name)
    os.replace(temporary, STATE)


def is_due(state, moment):
    if state.get("expires_at") and parse_date(state["expires_at"]) > moment + dt.timedelta(hours=48):
        return False
    if state.get("last_attempt") and parse_date(state["last_attempt"]) > moment - dt.timedelta(hours=4):
        return False
    return True


def run(command, log=None, timeout=180):
    env = dict(os.environ, DEVELOPER_DIR=XCODE)
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=log or subprocess.PIPE,
                            stderr=subprocess.STDOUT if log else subprocess.PIPE,
                            timeout=timeout, check=True)
    return result.stdout


def inspect_app(device, team, moment):
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE:
        raise ValueError("Refusing to install an unexpected app bundle.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(APP)])
    profile = plistlib.loads(run(["/usr/bin/security", "cms", "-D", "-i", str(APP / "embedded.mobileprovision")]))
    expiration = profile["ExpirationDate"].replace(tzinfo=UTC)
    entitlements = profile.get("Entitlements", {})
    if team not in profile.get("TeamIdentifier", []):
        raise ValueError("Provisioning team does not match the requested team.")
    if device not in profile.get("ProvisionedDevices", []):
        raise ValueError("Provisioning profile does not include this iPhone.")
    if entitlements.get("application-identifier") != team + "." + BUNDLE:
        raise ValueError("Provisioning profile belongs to a different app.")
    if expiration <= moment:
        raise ValueError("Xcode produced an expired provisioning profile. Open Xcode Signing & Capabilities to refresh signing.")
    return expiration


def renew(args):
    BUILD.mkdir(parents=True, exist_ok=True)
    # launchd and a manual invocation cannot build/install concurrently.
    with (BUILD / "renew.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another renewal is already running.")
            return 0
        state = read_state()
        moment = now()
        if args.scheduled:
            schedule_state = dict(state)
            if state.get("device") != args.device or state.get("team") != args.team:
                schedule_state.pop("expires_at", None)
            if state.get("attempt_device") != args.device or state.get("attempt_team") != args.team:
                schedule_state.pop("last_attempt", None)
            if not is_due(schedule_state, moment):
                return 0
        run_id = moment.strftime("%Y%m%dT%H%M%S.%fZ")
        log_path = BUILD / (run_id + ".log")
        state.update(last_attempt=moment.isoformat(), last_log=str(log_path),
                     attempt_device=args.device, attempt_team=args.team)
        save_state(state)
        try:
            with log_path.open("w") as log:
                print("Rebuilding and signing VayuSetu preview…", flush=True)
                run(["/usr/bin/xcodebuild", "-project", "VayuSetu.xcodeproj", "-scheme", "VayuSetu",
                     "-configuration", "Debug", "-destination", "id=" + args.device,
                     "-destination-timeout", "30", "-derivedDataPath", str(BUILD / "DerivedData"),
                     "-allowProvisioningUpdates", "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=" + args.team,
                     "clean", "build"], log, timeout=1800)
                expiration = inspect_app(args.device, args.team, now())
                print("Installing on the paired iPhone…", flush=True)
                run(["/usr/bin/xcrun", "devicectl", "device", "install", "app", "--device", args.device,
                     "--timeout", "120", str(APP)], log, timeout=150)
            old_expiry = state.get("expires_at")
            state.update(last_success=now().isoformat(), expires_at=expiration.isoformat(),
                         device=args.device, team=args.team, last_error=None)
            save_state(state)
            print("Rebuilt, signed and installed. Profile expires: " + expiration.astimezone().strftime("%b %d, %Y at %I:%M %p %Z"))
            if expiration <= now() + dt.timedelta(hours=48):
                print("Signing still uses a profile near expiry. This reinstall did not reset its seven-day lifetime. Open Xcode if later attempts cannot refresh it.")
            elif old_expiry and expiration <= parse_date(old_expiry):
                print("The existing profile was reused; its expiration has not changed.")
            print("Log: " + str(log_path))
            return 0
        except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
            message = str(error)
            state["last_error"] = message
            save_state(state)
            print("Renewal failed. Connect/unlock the trusted iPhone and check Xcode sign-in/signing. " + message, file=sys.stderr)
            print("Log: " + str(log_path), file=sys.stderr)
            return 1


def agent_plist(args):
    return {
        "Label": LABEL,
        "ProgramArguments": ["/bin/bash", str(ROOT / "scripts/renew-ios.sh"), "renew", "--scheduled",
                             "--device", args.device, "--team", args.team],
        "WorkingDirectory": str(ROOT), "RunAtLoad": True, "StartInterval": 3600,
        "ProcessType": "Background",
        "EnvironmentVariables": {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "DEVELOPER_DIR": XCODE},
        "StandardOutPath": str(BUILD / "scheduler.log"),
        "StandardErrorPath": str(BUILD / "scheduler-error.log"),
    }


def scheduler(args):
    domain = "gui/" + str(os.getuid())
    if args.action == "enable":
        if AGENT.exists():
            raise ValueError("Scheduler plist already exists. Run disable before enabling again.")
        BUILD.mkdir(parents=True, exist_ok=True)
        AGENT.parent.mkdir(parents=True, exist_ok=True)
        AGENT.write_bytes(plistlib.dumps(agent_plist(args)))
        try:
            run(["/bin/launchctl", "bootstrap", domain, str(AGENT)])
        except Exception:
            AGENT.unlink()
            raise
        print("Scheduler enabled: hourly checks; renewal attempts near expiry, at most every four hours.")
    elif args.action == "disable":
        if not AGENT.exists():
            print("Scheduler is already disabled.")
            return
        if plistlib.loads(AGENT.read_bytes()).get("Label") != LABEL:
            raise ValueError("Refusing to remove an unrelated LaunchAgent.")
        loaded = subprocess.run(["/bin/launchctl", "print", domain + "/" + LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if loaded:
            run(["/bin/launchctl", "bootout", domain + "/" + LABEL])
        AGENT.unlink()
        print("Scheduler disabled. Installed app and saved data remain.")
    elif args.action == "preview-schedule":
        print(plistlib.dumps(agent_plist(args)).decode())
    else:
        print("Scheduler: " + ("configured" if AGENT.exists() else "disabled"))
        state = read_state()
        for key in ("last_success", "expires_at", "last_attempt", "last_error", "last_log"):
            print(key.replace("_", " ") + ": " + str(state.get(key, "not recorded")))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["renew", "status", "enable", "disable", "preview-schedule"], nargs="?", default="renew")
    parser.add_argument("--device", default=DEVICE, help="Paired iPhone hardware UDID")
    parser.add_argument("--team", default=TEAM, help="Xcode development team ID")
    parser.add_argument("--scheduled", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        return renew(args) if args.action == "renew" else scheduler(args) or 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
