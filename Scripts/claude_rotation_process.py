"""Own one subprocess session and drain it before releasing fixture resources."""
import os
import signal
import subprocess
import time


class DriverCancelled(BaseException):
    pass


class OwnedProcess:
    def __init__(self, acknowledge_cleanup=lambda: None):
        self.acknowledge_cleanup = acknowledge_cleanup
        self.child = None
        self.spawning = False
        self.closing = False
        self.closed = False
        self.cancelled = False
        self.handlers = {}

    def __enter__(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            self.handlers[sig] = signal.signal(sig, self._cancel)
        return self

    def _cancel(self, *_):
        self.cancelled = True
        # Popen may have forked before returning its handle. Defer exceptions
        # until that handle is assigned; never leave an unowned child behind.
        if not self.spawning and not self.closing:
            raise DriverCancelled()

    def start(self, args, **kwargs):
        if self.cancelled:
            raise DriverCancelled()
        self.spawning = True
        try:
            self.child = subprocess.Popen(args, start_new_session=True, **kwargs)
        finally:
            self.spawning = False
        if self.cancelled:
            raise DriverCancelled()
        return self.child

    def _group_exists(self):
        self.child.poll()  # Reap the leader while waiting for descendants.
        # Darwin may report EPERM rather than ESRCH for killpg(pgid, 0)
        # after the last member exits. Read only numeric process-group IDs.
        listing = subprocess.run(['/bin/ps', '-axo', 'pgid='], check=True,
                                 capture_output=True, text=True)
        return str(self.child.pid) in listing.stdout.split()

    def close(self):
        if self.closed:
            return
        self.closing = True
        if self.child is None:
            self.closed = True
            self.acknowledge_cleanup()
            return
        for sig, grace in ((signal.SIGTERM, 2), (signal.SIGKILL, 5)):
            if not self._group_exists():
                break
            try:
                os.killpg(self.child.pid, sig)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + grace
            while self._group_exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            if not self._group_exists():
                break
        self.child.wait(timeout=1)
        if self._group_exists():
            raise RuntimeError('Owned process group still exists; retain fixture')
        self.closed = True
        self.acknowledge_cleanup()

    def __exit__(self, *_):
        try:
            self.close()
        finally:
            for sig, handler in self.handlers.items():
                signal.signal(sig, handler)
