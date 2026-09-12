"""Run with python3 -m unittest discover -s umbc/vnc/tests -v (Linux/WSL).

No VPN, real SSH, VNC viewer, or user sessions are touched. The SSH fixture
executes the actual inline remote Bash against a stateful TurboVNC fixture.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vnc-fresh-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.state = self.path / "sessions"
        self.state.write_text(":12\n")
        self.calls = self.path / "calls"
        self.stub("vncserver", r'''import os, sys
from pathlib import Path
state = Path(os.environ["STATE"])
with open(os.environ["CALLS"], "a") as f:
    f.write("vncserver " + " ".join(sys.argv[1:]) + "\n")
if sys.argv[1:] == ["-list"]:
    if os.environ.get("LIST_FAIL"): sys.exit(1)
    print("TurboVNC server sessions:\n\nX DISPLAY #     PROCESS ID")
    for display in state.read_text().splitlines(): print(display + "    12345")
elif len(sys.argv) == 3 and sys.argv[1] == "-kill":
    if os.environ.get("KILL_FAIL"): sys.exit(1)
    if not os.environ.get("REMAIN"):
        rows = [s for s in state.read_text().splitlines() if s != sys.argv[2]]
        state.write_text("".join(s + "\n" for s in rows))
else: sys.exit(99)
''')
        self.stub("ssh", r'''import os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f: f.write("ssh " + " ".join(args) + "\n")
if "-M" in args or "-O" in args: sys.exit(0)
command = args[-1]
state = Path(os.environ["STATE"])
if command == "bash -s":
    source = sys.stdin.read().replace("/umbc/software/TurboVNC/bin/vncserver", os.environ["MOCK_VNCSERVER"])
    sys.exit(subprocess.run(["bash"], input=source, text=True).returncode)
elif "launch_vncserver_" in command:
    if not state.read_text(): state.write_text(":20\n")
elif command.endswith("list_first_vnc_server.sh"):
    print(state.read_text().splitlines()[0])
elif "get_vncpasswd.sh" in command: print("synthetic-password")
else: sys.exit(99)
''')
        self.stub("viewer", 'import sys\nsys.stdin.read()\n')
        self.stub("ss", 'pass\n')
        self.stub("curl", r'''import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
shutil.copyfile(Path(os.environ["SOURCE_ROOT"]) / args[-1].rsplit("/", 1)[-1], args[args.index("--output") + 1])
''')
        self.env = dict(os.environ, PATH=str(self.path) + ":" + os.environ["PATH"],
                        STATE=str(self.state), CALLS=str(self.calls),
                        MOCK_VNCSERVER=str(self.path / "vncserver"),
                        VNCVIEWER=str(self.path / "viewer"), SOURCE_ROOT=str(ROOT))

    def stub(self, name, code):
        file = self.path / name
        file.write_text("#!/usr/bin/env python3\n" + code)
        file.chmod(0o700)

    def run_launcher(self, *options, expected=0, direct=False):
        script = "launch_client_vnc_wsl_new.sh" if direct else "launch_vnc_latest.sh"
        flags = list(options) if direct else ["--no-vpn", *options]
        result = subprocess.run(["bash", str(ROOT / script), *flags, "student@lab.example"],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("synthetic-password", result.stdout + result.stderr)
        return result

    def log(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_default_reuses_session_without_restart_commands(self):
        self.run_launcher()
        self.assertEqual(self.state.read_text(), ":12\n")
        self.assertNotIn("vncserver ", self.log())
        self.assertIn("launch_vncserver_icewm.sh", self.log())

    def test_fresh_replaces_all_listed_sessions_then_starts(self):
        self.state.write_text(":12\n:100\n")
        result = self.run_launcher("--fresh")
        self.assertEqual(self.state.read_text(), ":20\n")
        self.assertIn("Existing VNC session found on :12.", result.stdout)
        self.assertIn("vncserver -kill :12", self.log())
        self.assertIn("vncserver -kill :100", self.log())
        self.assertLess(self.log().index("vncserver -kill :100"), self.log().index("launch_vncserver_icewm.sh"))
        self.assertIn("get_vncpasswd.sh :20", self.log())
        self.assertIn("localhost:5920", self.log())

    def test_empty_list_starts_without_killing(self):
        self.state.write_text("")
        self.run_launcher("--fresh")
        self.assertNotIn("vncserver -kill", self.log())
        self.assertEqual(self.state.read_text(), ":20\n")

    def test_fresh_openbox_both_flag_orders(self):
        for options in (("--fresh", "--openbox"), ("--openbox", "--fresh")):
            with self.subTest(options=options):
                self.calls.unlink(missing_ok=True)
                self.state.write_text(":12\n")
                self.run_launcher(*options)
                self.assertIn("vncserver -kill :12", self.log())
                self.assertIn("launch_vncserver_openbox.sh", self.log())
                self.assertNotIn("launch_vncserver_icewm.sh", self.log())

    def test_openbox_without_fresh_still_reuses(self):
        self.run_launcher("--openbox")
        self.assertEqual(self.state.read_text(), ":12\n")
        self.assertNotIn("vncserver ", self.log())

    def test_failures_abort_before_starting_or_viewing(self):
        for variable in ("LIST_FAIL", "KILL_FAIL", "REMAIN"):
            with self.subTest(variable=variable):
                self.calls.unlink(missing_ok=True)
                self.state.write_text(":12\n")
                self.env[variable] = "1"
                self.run_launcher("--fresh", expected=1)
                del self.env[variable]
                self.assertNotIn("launch_vncserver_", self.log())
                self.assertNotIn("get_vncpasswd.sh", self.log())
                self.assertIn("-O exit", self.log())

    def test_invalid_list_validated_before_any_kill(self):
        for invalid in (":bad", ":99999"):
            with self.subTest(invalid=invalid):
                self.calls.unlink(missing_ok=True)
                self.state.write_text(":12\n" + invalid + "\n")
                self.run_launcher("--fresh", expected=1)
                self.assertNotIn("vncserver -kill", self.log())
                self.assertNotIn("launch_vncserver_", self.log())

    def test_direct_client_accepts_fresh_and_openbox(self):
        self.run_launcher("--fresh", "--openbox", direct=True)
        self.assertIn("launch_vncserver_openbox.sh", self.log())

    def test_unknown_option_rejected_without_ssh(self):
        self.run_launcher("--unknown", expected=2)
        self.assertEqual(self.log(), "")

    def test_help_through_old_bootstrap(self):
        result = subprocess.run(["bash", str(ROOT / "launch_vnc_latest.sh"), "--help"],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--fresh", result.stdout)
        self.assertEqual(self.log(), "")


if __name__ == "__main__":
    unittest.main()
