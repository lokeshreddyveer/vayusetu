import datetime as dt
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('renewal', Path(__file__).resolve().parents[1] / 'scripts/renew_ios.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)

class RenewalTests(unittest.TestCase):
    def test_expiration_drives_schedule_not_reinstall_date(self):
        moment = dt.datetime(2026, 10, 10, tzinfo=r.UTC)
        self.assertFalse(r.is_due({'expires_at': (moment + dt.timedelta(days=3)).isoformat()}, moment))
        self.assertTrue(r.is_due({'expires_at': (moment + dt.timedelta(hours=47)).isoformat()}, moment))
        self.assertFalse(r.is_due({'last_attempt': (moment - dt.timedelta(hours=1)).isoformat()}, moment))
        self.assertTrue(r.is_due({'last_attempt': (moment - dt.timedelta(hours=5)).isoformat()}, moment))

    def attempt(self, failure_at):
        from argparse import Namespace
        args = Namespace(device=r.DEVICE, team=r.TEAM, scheduled=False)
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            calls = []
            def command(argv, *args, **kwargs):
                calls.append(argv)
                if failure_at == 'build' or ('devicectl' in argv and failure_at == 'install'):
                    raise subprocess.CalledProcessError(1, argv)
            with patch.object(r, 'BUILD', build), patch.object(r, 'STATE', build / 'state.json'), patch.object(r, 'run', side_effect=command), patch.object(r, 'inspect_app') as inspect:
                expiry = r.now() + dt.timedelta(days=1)
                r.save_state({'expires_at': expiry.isoformat(), 'last_success': 'previous'})
                inspect.side_effect = ValueError('expired profile') if failure_at == 'profile' else None
                inspect.return_value = r.now() + dt.timedelta(days=7)
                self.assertEqual(r.renew(args), 1)
                state = r.read_state()
                self.assertEqual(state['expires_at'], expiry.isoformat())
                self.assertEqual(state['last_success'], 'previous')
                self.assertTrue(state['last_error'])
                if failure_at != 'install':
                    self.assertFalse(any('devicectl' in c for c in calls))

    def test_build_failure_preserves_installed_expiry(self): self.attempt('build')
    def test_invalid_profile_never_installs(self): self.attempt('profile')
    def test_install_failure_preserves_installed_expiry(self): self.attempt('install')

if __name__ == '__main__': unittest.main()
