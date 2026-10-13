import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from tools.gates.m12_003_supervision import run_owned


class OwnedProcessTests(unittest.TestCase):
    def setUp(self):
        parent = Path(os.environ.get('TMPDIR', Path.home() / '.cache/agent-tmp'))
        parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='m12-supervision-', dir=parent)
        self.work = Path(self.temp.name)
        self.pid_file = self.work / 'child.pid'
        self.environment = dict(os.environ, TMPDIR=str(self.work), TMP=str(self.work), TEMP=str(self.work))

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, exit_parent=False):
        return [sys.executable, '-c',
            'import os,pathlib,signal,sys; child=os.fork(); '
            '\nif child == 0:\n signal.signal(signal.SIGTERM,signal.SIG_IGN); signal.pause()'
            '\nelse:\n pathlib.Path(sys.argv[1]).write_text(str(child)); '
            + ('sys.exit(7)' if exit_parent else 'signal.pause()'), str(self.pid_file)]

    def wait_ready(self):
        stop = time.monotonic() + 5
        while time.monotonic() < stop:
            try:
                contents = self.pid_file.read_text().strip()
            except FileNotFoundError:
                contents = ''
            if contents:
                try:
                    pid = int(contents)
                except ValueError:
                    pid = 0
                if pid > 0:
                    return pid
            time.sleep(.005)
        self.fail('native fork fixture did not write a complete PID')

    def test_wait_ready_ignores_empty_malformed_and_nonpositive_pid_contents(self):
        self.pid_file.touch()

        def publish_pid():
            for contents in ('not-a-pid', '0', '-7', '12345'):
                time.sleep(.02)
                self.pid_file.write_text(contents)

        writer = threading.Thread(target=publish_pid)
        writer.start()
        try:
            self.assertEqual(self.wait_ready(), 12345)
        finally:
            writer.join(5)
        self.assertFalse(writer.is_alive())
    def assert_gone(self, pid):
        path = Path('/proc') / str(pid) / 'stat'
        if path.exists():
            raw = path.read_text()
            self.assertEqual(raw[raw.rindex(')') + 2:].split()[0], 'Z', 'live owned descendant remains')

    def run_fixture(self, argv, **options):
        return run_owned(argv, cwd=self.work, environment=self.environment,
            output=self.work/'output', timeout_seconds=options.pop('timeout_seconds', 5),
            grace_seconds=.05, **options)

    def test_timeout_kills_term_ignoring_descendant(self):
        result = self.run_fixture(self.fixture(), timeout_seconds=.3)
        self.assertEqual(result['completion'], 'TIMEOUT')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['remaining_live_owned_processes'], 0)
        self.assert_gone(self.wait_ready())

    def test_cancellation_kills_real_parent_and_child(self):
        cancellation = threading.Event()
        ready = []
        def cancel():
            ready.append(self.wait_ready())
            cancellation.set()
        thread = threading.Thread(target=cancel)
        thread.start()
        result = self.run_fixture(self.fixture(), cancellation=cancellation)
        thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(result['completion'], 'CANCELLED')
        self.assertEqual(result['remaining_live_owned_processes'], 0)
        self.assert_gone(ready[0])

    def test_failed_parent_exit_still_cleans_child(self):
        result = self.run_fixture(self.fixture(exit_parent=True))
        self.assertEqual(result['exit_code'], 7)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['completion'], 'EXIT')
        self.assert_gone(self.wait_ready())

    def test_sampler_exception_still_cleans_native_child(self):
        owner = self
        class BrokenSampler:
            def is_set(self):
                owner.wait_ready()
                raise RuntimeError('sampler failed')
        with self.assertRaises(RuntimeError):
            self.run_fixture(self.fixture(), cancellation=BrokenSampler())
        self.assert_gone(self.wait_ready())

    def test_runaway_output_is_failure_not_success(self):
        result = self.run_fixture([sys.executable, '-c',
            'import os; b=b"x"*1024\nwhile True: os.write(1,b)'], maximum_log_bytes=4096)
        self.assertEqual(result['completion'], 'OUTPUT_LIMIT')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['remaining_live_owned_processes'], 0)
        self.assertEqual(result['stdout_bytes'], 4096)
        self.assertLessEqual(result['stderr_bytes'], 4096)


if __name__ == '__main__':
    unittest.main()
