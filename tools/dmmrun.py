#!/usr/bin/env python3
"""Helper to load/run TSP (Lua) scripts on a Keithley DMM6500 over raw socket 5025."""
import atexit
import fcntl
import os
import socket
import sys
import time

_LOCK_PATH = '/tmp/dmm6500.lock'
_lock_fh = None
# PID of whoever refused us, when it could be read back -- so the error can name them.
_lock_holder = [None]


def acquire_single_instance(blocking=False):
    """The DMM6500 accepts only ONE controlling socket. Two concurrent scripts
    silently steal each other's replies (reads return '' or BrokenPipe), so
    serialise access with an flock. Returns True if this process holds the lock."""
    global _lock_fh
    if _lock_fh is not None:
        return True
    # 'a+', NOT 'w'. Opening for write TRUNCATES before flock is even attempted, so a client that
    # then fails to acquire has already destroyed the incumbent's PID -- which is exactly why the
    # refusal could not say who was holding it. The flock itself was always sound: it is
    # kernel-released when the holder dies, SIGKILL included, so a crashed run cannot wedge the
    # bench and the file being left behind means nothing.
    fh = open(_LOCK_PATH, 'a+')
    flags = fcntl.LOCK_EX if blocking else (fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        fcntl.flock(fh, flags)
    except OSError:
        # Read the holder back so the caller can name it. Best effort: an older holder may predate
        # this and have written nothing.
        try:
            fh.seek(0)
            _lock_holder[0] = fh.read(64).strip() or None
        except Exception:
            pass
        fh.close()
        return False
    fh.seek(0)
    fh.truncate()
    fh.write(str(os.getpid()))
    fh.flush()
    _lock_fh = fh
    atexit.register(_release_lock)
    return True


def release_single_instance():
    """Give the single-client lock back without waiting for process exit.

    Needed by anything that talks to the DMM and then SPAWNS a child that also needs to: the lock
    is held per process, so a parent that merely closed its socket still blocks every child. That
    is what it looks like when a release sweep refuses its own hardware stages.
    """
    _release_lock()


def _release_lock():
    global _lock_fh
    if _lock_fh is not None:
        try:
            fcntl.flock(_lock_fh, fcntl.LOCK_UN)
            _lock_fh.close()
        except Exception:
            pass
        _lock_fh = None

IP = '10.0.1.151'
PORT = 5025
DST_PORT = 5030   # Dead Socket Termination: closing a connection here drops all stale sockets


def clear_dead_sockets(ip=IP, timeout=8):
    """The DMM6500 only allows one controlling socket. A killed client leaves a
    'dead socket' that silently swallows replies. Connecting to the DST port and
    closing it terminates all existing ethernet connections (Ref manual 2-21)."""
    import time as _t
    try:
        s = socket.socket()
        s.settimeout(timeout)
        s.connect((ip, DST_PORT))
        _t.sleep(0.5)
        s.close()
        _t.sleep(2.5)
        return True
    except Exception:
        return False


class DMM:
    def __init__(self, ip=IP, port=PORT, timeout=180, recover=True, exclusive=True):
        if exclusive and not acquire_single_instance():
            # NAME THE HOLDER. The flock is kernel-released when its owner dies, so a refusal always
            # means a LIVE client -- never a leftover file. Saying which pid turns "why is the bench
            # refusing me" into one `ps` command, and stops the next person deleting the lock file in
            # the belief it is stale. It is not, and deleting it does not help.
            who = _lock_holder[0]
            extra = ''
            if who:
                extra = ' (held by pid %s' % who
                try:
                    os.kill(int(who), 0)
                    extra += ', which is RUNNING - stop it rather than removing the lock)'
                except (OSError, ValueError):
                    extra += ', which is not responding to signal 0)'
            raise RuntimeError(
                'another DMM6500 client already holds %s%s - refusing to open a '
                'second control socket (it would corrupt both sessions)' % (_LOCK_PATH, extra))
        self.ip = ip
        self.port = port
        self._timeout = timeout
        self._open()
        if recover and not self.alive():
            # Stale socket from a previous run: clear it and reconnect.
            self.close()
            clear_dead_sockets(ip)
            self._open()

    def _open(self):
        self.s = socket.socket()
        self.s.settimeout(self._timeout)
        self.s.connect((self.ip, self.port))
        self.buf = b''
        self.drain()

    def alive(self):
        return self.q('print("OK")', timeout=8) == 'OK'

    def drain(self):
        self.s.setblocking(False)
        try:
            while True:
                if not self.s.recv(65536):
                    break
        except Exception:
            pass
        self.s.setblocking(True)
        self.s.settimeout(180)
        self.buf = b''

    def send(self, cmd):
        self.s.sendall((cmd + '\n').encode())

    def line(self, timeout=None):
        if timeout is not None:
            self.s.settimeout(timeout)
        while b'\n' not in self.buf:
            try:
                d = self.s.recv(65536)
            except socket.timeout:
                return None
            if not d:
                return None
            self.buf += d
        ln, _, self.buf = self.buf.partition(b'\n')
        return ln.decode(errors='replace').strip()

    def q(self, cmd, timeout=30):
        """Send `cmd` and read ONE reply line.

        IMPORTANT: the instrument only replies if the statement prints. Calling
        q() on a statement with no print() blocks for the whole timeout and
        returns None, which looks exactly like a failure. Use exec() for
        statements that produce no output.
        """
        self.drain()
        self.send(cmd)
        return self.line(timeout)

    def exec(self, cmd, timeout=30):
        """Run a statement that produces no output, then confirm liveness.

        Appends a sentinel print so there is always exactly one line to read.
        """
        self.drain()
        self.send(cmd + ' print("__OK__")')
        r = self.line(timeout)
        return r == '__OK__'

    def load_script(self, name, body, run=True, timeout=300, sentinel='===DONE==='):
        """Load a named script via loadscript/endscript, optionally run and stream output.

        NOTE: loadscript only STORES the chunk. Its functions do not exist until
        the chunk itself is executed once (call `name()`), which is what run=True
        does here. Reloading an existing name raises 1408, so drop it first.
        """
        self.drain()
        # A name already loaded must be cleared or the reload raises
        # "1408 A script with the same name already exists".
        #
        # script.delete() wants the script OBJECT, not its name string - passing
        # a string gives "1138 Parameter 1, expected type 'number', but found
        # type 'unknown'". A leftover global that is not a script (e.g. a plain
        # function) just has to be set to nil. pcall keeps a failure here from
        # aborting the load.
        #
        # script.delete() succeeds but logs "-104 Data type error" to the event log
        # whichever way the script is identified. That is cosmetic -- the name really
        # is freed -- but it lands in the same event log that judges whether the APP
        # is healthy, so it is cleared here. Only a re-load reaches this branch, so a
        # first load after a power cycle shows a clean log either way and it is every
        # reload afterwards that would carry exactly one -104.
        self.q('if %s ~= nil then '
               '  pcall(function() script.delete(%s) end) '
               '  %s = nil '
               '  eventlog.clear() '
               'end print("__CLEARED__")' % (name, name, name), timeout=30)
        self.drain()
        self.send('loadscript ' + name)
        for ln in body.splitlines():
            self.send(ln)
        self.send('endscript')
        time.sleep(0.3)
        if not run:
            return []
        self.send(name + '()')
        out = []
        while True:
            ln = self.line(timeout)
            if ln is None:
                out.append('<TIMEOUT waiting for output>')
                break
            if ln == sentinel:
                break
            out.append(ln)
        return out

    def errors(self):
        """Drain the event log, returning any entries."""
        msgs = []
        for _ in range(40):
            c = self.q('print(eventlog.getcount())')
            try:
                c = int(float(c))
            except (TypeError, ValueError):
                break
            if c == 0:
                break
            msgs.append(self.q('print(eventlog.next())'))
        return msgs

    def restore_display(self):
        """Bring the panel back to a sane, visible state.

        Long sessions and bad display-setter arguments can leave the screen dark
        or stuck on a custom app screen. This is recoverable in software; a power
        cycle is never needed.
        """
        try:
            # 25 %, NEVER 100. The operator's standing instruction is that this panel's backlight is
            # never set above 30 %, and the firmware's only steps are 100/75/50/25 -- so 25 is the one
            # this may use. It used to restore 100, which meant every tool that closed with
            # restore=True turned the lights back up on an instrument left running overnight.
            self.q('display.lightstate = display.STATE_LCD_25', timeout=20)
            self.q('display.changescreen(display.SCREEN_HOME)', timeout=20)
        except Exception:
            pass

    def close(self, restore=False):
        if restore:
            self.restore_display()
        try:
            self.s.close()
        except Exception:
            pass


if __name__ == '__main__':
    d = DMM()
    print(d.q('print(localnode.model, localnode.version)'))
    d.close()
