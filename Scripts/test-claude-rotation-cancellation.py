#!/usr/bin/env python3
"""Synthetic process tests only: no Claude, Security, keychain, or network."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

MODULE = str(Path(__file__).resolve().parent)
WORKER = r'''
import json,os,signal,subprocess,sys,time
sys.path.insert(0,sys.argv[1])
from claude_rotation_process import OwnedProcess, DriverCancelled
mode,output=sys.argv[2:]
real_popen=subprocess.Popen
def spawn(*args,**kwargs):
    child=real_popen(*args,**kwargs)
    if kwargs.get('start_new_session'):
        open(output,'w').write(json.dumps({'pid':child.pid}))
        if mode=='spawn-race': os.kill(os.getpid(),signal.SIGTERM)
    return child
subprocess.Popen=spawn
try:
    with OwnedProcess(lambda: open(output+'.ack','w').write('cleaned')) as owner:
        code='import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(120)'
        if mode=='descendants':
            code="import subprocess,sys,time;subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)']);time.sleep(120)"
        owner.start([sys.executable,'-c',code],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        while True: time.sleep(.02)
except DriverCancelled:
    pass
open(output+'.done','w').write('cleaned')
'''


class CancellationTests(unittest.TestCase):
    def exercise(self, mode):
        with tempfile.TemporaryDirectory(prefix='rotation-cancellation-') as directory:
            output = Path(directory) / 'child.json'
            driver = subprocess.Popen([sys.executable, '-c', WORKER, MODULE, mode, str(output)])
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while not output.exists():
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(.02)
                child_pid = json.loads(output.read_text())['pid']
                if mode != 'spawn-race':
                    time.sleep(.2)
                    driver.terminate()
                self.assertEqual(driver.wait(timeout=10), 0)
                self.assertTrue(Path(str(output) + '.done').exists())
                self.assertTrue(Path(str(output) + '.ack').exists())
                groups = subprocess.check_output(['/bin/ps', '-axo', 'pgid='], text=True).split()
                self.assertNotIn(str(child_pid), groups)
            finally:
                if driver.poll() is None:
                    driver.kill(); driver.wait(timeout=3)
                if child_pid:
                    try: os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_sigterm_kills_stubborn_child(self):
        self.exercise('stubborn')

    def test_sigterm_kills_child_and_descendant(self):
        self.exercise('descendants')

    def test_sigterm_during_popen_before_handle_assignment(self):
        self.exercise('spawn-race')


if __name__ == '__main__':
    unittest.main()
