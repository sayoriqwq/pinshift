#!/usr/bin/env python3
"""Run with Python 3; exercises registration without Nix builds or device access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    source = Path(__file__).resolve().parents[1]
    fish = shutil.which('fish')
    assert fish, 'Run this check inside the project tool environment (Fish required).'
    with tempfile.TemporaryDirectory(prefix="pinshift command '") as temporary:
        root = Path(temporary).resolve()
        checkout = root / 'checkout with spaces'
        (checkout / 'bin').mkdir(parents=True)
        for name in ('pinshift', 'pinshift-command'):
            shutil.copy2(source / 'bin' / name, checkout / 'bin' / name)
        fake_tools = root / 'fake tools'
        fake_tools.mkdir()
        nix = fake_tools / 'nix'
        nix.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        nix.chmod(0o755)
        environment = dict(os.environ, PATH=str(fake_tools) + os.pathsep + os.environ['PATH'])
        destination = root / 'commands'
        entry = destination / 'pinshift'

        def command(action, success=True):
            result = subprocess.run(
                [fish, '--no-config', str(checkout / 'bin' / 'pinshift'),
                 action, '--bin-dir', str(destination)],
                env=environment, text=True, capture_output=True,
            )
            assert (result.returncode == 0) == success, result.stdout + result.stderr
            return result

        command('register')
        # Invoke outside the checkout; arguments must reach Nix unchanged.
        result = subprocess.run([str(entry), 'help', 'two words', "a'b"],
                                cwd=root, text=True, capture_output=True, check=True)
        assert result.stdout.splitlines() == [
            '--extra-experimental-features', 'nix-command flakes', 'develop',
            str(checkout), '--command', 'fish', str(checkout / 'bin' / 'pinshift'),
            'help', 'two words', "a'b",
        ], result.stdout
        command('register')  # Safe refresh of a managed entry.
        command('unregister')
        assert not entry.exists() and (checkout / 'bin' / 'pinshift').exists()
        command('unregister')  # Idempotent removal.
        entry.write_text('unrelated command\n')
        command('register', success=False)
        command('unregister', success=False)
        assert entry.read_text() == 'unrelated command\n'
        entry.unlink()
        other = root / 'unrelated'
        other.write_text('keep me')
        entry.symlink_to(other)
        command('register', success=False)
        command('unregister', success=False)
        assert other.read_text() == 'keep me'
        entry.unlink()
        command('register')
        (checkout / 'bin' / 'pinshift').unlink()
        missing = subprocess.run([str(entry), 'help'], text=True, capture_output=True)
        assert missing.returncode == 127 and 'Register again' in missing.stderr
    print('PASS: registration, forwarding, refresh, removal, collision and missing-checkout checks')


if __name__ == '__main__':
    main()
