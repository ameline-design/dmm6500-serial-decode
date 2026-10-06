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
# The instrument's answer when something else holds the interpreter. Measured every time for a
# chunk RUN with the app's own screen in front; for a plain statement it is a collision at a rate,
# and WHAT it collides with is not established -- see DMM.exec, which does not name the tick either.
# The statement does NOT run, so re-sending it is safe.
# THE REFUSAL, EXACTLY AS THE INSTRUMENT SENDS IT, and the match has to be exact. Re-sending a
# statement is safe only if it did NOT run, and the whole inference rests on this line being the
# instrument's ONLY answer -- it refused, so there is no reply coming and no sentinel either.
#
# A SUBSTRING TEST IS NOT SAFE, which is the trap here. This instrument volunteers event lines on
# the control socket when the app sets localnode.showevents, and one quoting this phrase would also
# arrive first, ahead of a perfectly good reply -- so re-sending on a substring hit means two
# captures and the real reply left in the buffer, putting every later read one behind.
#
# WAITING FOR THE SENTINEL INSTEAD DOES NOT WORK, which is why this is a format test. The __OK__ of
# a statement that really is running arrives when the statement FINISHES: sdec.capture() is 1.9-4 s
# measured, options_apply about 4 s, a 32 kB press tens of seconds. Any fixed settle short enough to
# be worth having is shorter than those, so it would expire and conclude "refused" on precisely the
# expensive statements where a double run costs most.
#
# SO IT FAILS TOWARD SAFETY: a line that is not exactly this is treated as an ordinary stray and the
# read goes on waiting for the sentinel, which is the correct behaviour for a statement that ran. A
# re-worded refusal in some later firmware therefore costs one timeout, not a double execution.
REFUSAL_LINE = 'FAILURE: A command from another interface is running, use ABORT to stop it'
REFUSE_RETRIES = 4
# Longer than one 0.5 s tick period, so a retry does not land in the same slot that refused it.
REFUSE_WAIT = 0.6
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
        # Lines that arrived where a sentinel was expected -- see exec(). Kept rather than dropped
        # silently, because the only thing worse than an unsolicited event line is one nobody knows
        # about; the last few are worth printing when a harness reports something impossible.
        self.stray = 0
        self.strays = []
        # How many statements had to be re-sent because the panel was mid-handler. Nonzero is
        # normal with a live app; a large number means something is holding the panel.
        self.refusals = 0
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

        A REFUSED STATEMENT IS RE-SENT, and this is the dangerous half of the two.
        "FAILURE: A command from another interface is running" arrives on the socket
        looking exactly like a reply, so without this q() HANDS THE REFUSAL BACK AS
        DATA: a caller asking for a number gets that sentence, and whatever it does
        with it -- float() raising, a comparison against a string, a field written
        into a results table -- is a harness fault with no bad instrument behind it.
        MEASURED RATE, app screen in front and the key tick live, 18 queries interleaved
        with tight loops of sdec.ui_tick(): 3 refusals caught and re-sent, 0 replies
        handed back as a refusal. Without the retry that is three bogus values.

        Only an EXACT match on the refusal line is re-sent -- see REFUSAL_LINE. A reply
        that merely quotes the phrase is handed back as the reply it is.
        """
        for _try in range(REFUSE_RETRIES):
            self.drain()
            self.send(cmd)
            r = self.line(timeout)
            if r is None or r.strip() != REFUSAL_LINE:
                return r
            self.refusals += 1
            time.sleep(REFUSE_WAIT)
        return None

    def exec(self, cmd, timeout=30):
        """Run a statement that produces no output, then confirm liveness.

        Appends a sentinel print and READS UNTIL IT ARRIVES, discarding anything ahead of it.

        NOT "exactly one line to read", which is what this assumed. An app under test sets
        localnode.showevents, and on this instrument that makes the DMM print event lines on the
        control socket UNSOLICITED -- so a single read can return an event line instead of the
        sentinel, leaving __OK__ in the buffer and every later reply one behind. It is silent and it
        cascades: the next load_script arrives mangled ("Script contained 'endscript' without
        starting with 'loadscript'", every error at line 1), and the next q() for a number returns
        the string "__OK__". Measured twice, as two bench_smoke panel stages that died in 0.0 min.

        Stray lines are counted rather than dropped quietly, so a caller can tell this happened.

        A REFUSED STATEMENT IS RE-SENT, because a refusal means it never ran. "FAILURE: A command
        from another interface is running" is a real answer from this instrument, measured on
        1.7.17a for a chunk RUN, where the app's own screen being in front is enough on its own to
        get it every time (see load_script). It is not the sentinel, so without this the read waits
        for an __OK__ that cannot come and the caller can only report a timeout.

        PLAIN STATEMENTS GET IT TOO, at a rate: 3 of 18 queries came back as the refusal in one
        sequence. 40 execs with the app's screen in front and nothing else going on all passed, so
        the screen alone is not enough -- it is a collision with something holding the interpreter.

        WHAT IT COLLIDES WITH IS NOT ESTABLISHED, and the obvious suspect is not safe to name. The
        app's 2 Hz key tick is the only thing on this panel that runs unprompted, but in the
        sequence that provoked those 3 the queries were interleaved with HOST-SIDE loops of 200
        sdec.ui_tick() calls -- so the other interface may equally have been this socket's own
        previous statement still finishing. Distinguishing them needs a provocation with no
        instrument-side work of its own, which has not been done.

        ONLY AN EXACT MATCH ON THE FIRST LINE COUNTS, and that is what makes the "nothing ran"
        inference safe rather than merely likely. A genuine refusal is the instrument's only answer,
        so it arrives first and alone; a volunteered event line quoting the same phrase is first too
        but has the real reply behind it. The discriminator is the FORMAT, not the timing -- see
        REFUSAL_LINE for why no amount of waiting for the sentinel can do this job.

        NOT PROVEN TO BE THE CAUSE OF THE ONE STAGE FAILURE IT WAS WRITTEN FOR. A bench_smoke panel
        stage died on exactly this timeout at bench_sync's clear-result step and then passed standing
        alone with 45 presses and 0 events, so the refusal is the mechanism that fits rather than one
        caught in the act there. self.refusals says whether it ever actually fires.
        """
        for _try in range(REFUSE_RETRIES):
            self.drain()
            self.send(cmd + ' print("__OK__")')
            refused = False
            # Bounded, so a genuinely chatty command cannot spin here.
            for nread in range(256):
                r = self.line(timeout)
                if r is None:
                    break
                if r == '__OK__':
                    return True
                self.stray += 1
                self.strays.append(r)
                # FIRST LINE ONLY. See the docblock: a refusal is the reply, so it arrives first
                # and nothing executed -- which is what makes re-sending safe for sdec.capture()
                # and every other non-idempotent statement exec() carries. The same phrase arriving
                # later is a volunteered event line, and re-sending on that would run the statement
                # twice. Counted, so a run that needed it is not silent about it.
                # EXACT, AND FIRST LINE ONLY. See REFUSAL_LINE: anything else carrying the phrase
                # is an ordinary stray, and falling through to keep reading for the sentinel is
                # what stops a second sdec.capture() and the one-behind desync.
                if nread == 0 and r.strip() == REFUSAL_LINE:
                    self.refusals += 1
                    refused = True
                    break
            if not refused:
                return False
            time.sleep(REFUSE_WAIT)
        return False

    def restore_panel(self):
        """Put the app's own screen back in front after a load sent the panel HOME.

        Only when a UI actually exists: before the first start() sdec.built is nil and
        start() does this itself, so restoring here would fight it. With the app built --
        a helper script loaded mid-session, which is what bench_panel does -- this is
        what keeps the pixel grabs looking at the app rather than at HOME.

        Returning to the app's screen also restarts its 2 Hz key tick, because a timer
        runs only while its own screen is active. Nothing has to re-arm it.

        THE `ui_scr ~= nil` TEST IS LOAD-BEARING, not belt and braces. sdec.stop() does not clear
        sdec.built -- only start()'s own failure path does -- but ui_destroy() nils ui_scr, so after
        a teardown `built` is still true and this test is the only thing standing between
        restore_panel and a changescreen onto a deleted screen handle.

        It always returns to sdec.ui_scr, never to the options screen. Every caller today loads
        before its own sequence, so nothing is affected.

        Runs on the way out of a load that may itself have failed, so it never raises.
        """
        self.exec('if sdec ~= nil and sdec.built and sdec.ui_scr ~= nil then '
                  '  pcall(function() display.changescreen(sdec.ui_scr) end) '
                  'end', timeout=30)

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
        # THE PANEL GOES HOME FIRST, and that is what makes a load reliable. With the app's OWN
        # screen in front, RUNNING the loaded chunk is refused -- "FAILURE: A command from another
        # interface is running, use ABORT to stop it" -- because the front panel showing a live TSP
        # app IS the other interface. Measured on 1.7.17a against the 752 kB app body:
        #
        #     app's screen in front    301.3 s, the run REFUSED, and the PREVIOUS app left loaded
        #     display.SCREEN_HOME        1.4 s, clean, no retry -- 2 of 2 by hand, then
        #                                2 of 2 again through this function (1.4, 1.2 s)
        #
        # IT IS THE RUN, NOT THE TRANSFER. loadscript itself goes through either way: three loads
        # with run=False and the app's screen up took 0.7-1.9 s and defined the name. So the failure
        # mode is a chunk that is stored and never executed, which looks exactly like a load that
        # did not happen -- `type(name) ~= nil` passes, and the functions are not there.
        #
        # ABORT does not clear it; there is nothing hung to abort. Going HOME releases the panel,
        # and it also stops the app's 2 Hz key tick for free, a timer running only while its own
        # screen is active. restore_panel() puts the app's screen back afterwards.
        self.exec('pcall(function() display.changescreen(display.SCREEN_HOME) end)', timeout=30)
        # LOADED WITH VERIFY-AND-RETRY, because the opening `loadscript` line can still be lost in
        # TRANSFER. That is a different failure from the refused run above and it is not fixed by
        # going HOME: it shows up as "Script contained 'endscript' keyword without starting with
        # 'loadscript'", and the transfer itself went through 3 of 3 with the app's screen up. Its
        # measured variable is pacing. On 1.7.17a against bench_panel's 58-line body, 2659 bytes:
        #
        #     one burst, no delay      3 of 6 loads clean; the rest reported
        #                              "Script contained 'endscript' keyword without starting with
        #                              'loadscript'" and a page of syntax errors
        #     0.05 s every 512 bytes   2 of 5 clean
        #     0.03 s every line        0 of 6 -- WORSE, and the errors change shape: every line
        #                              parses as its own chunk, which is what leaving loadscript
        #                              accumulation mode looks like. Pacing is not the fix; the
        #                              accumulation ends on an idle gap. Do not add a sleep.
        #
        # A failed load used to be silent on this side and lethal later: the press helper was simply
        # never defined, so bench_panel's every press timed out at 300 s and the stage read as an app
        # fault. It cost three bench_smoke runs. `type(name) ~= nil` is the honest check -- loadscript
        # defines the name only if it saw the opening line -- and a reload needs the clear step again.
        loaded = False
        for attempt in range(4):
            # exec(), NOT q(). The clear step calls script.delete(), which logs -104 -- and with the
            # app under test holding localnode.showevents at SEV_ERROR the instrument PRINTS that
            # event on the control socket. A one-line read then returns the event instead of the
            # acknowledgement, leaving it buffered and every later reply one behind.
            self.exec('if %s ~= nil then '
                      '  pcall(function() script.delete(%s) end) '
                      '  %s = nil '
                      '  eventlog.clear() '
                      'end' % (name, name, name), timeout=30)
            # script.delete() logs asynchronously, so the event can still be in flight after exec's
            # sentinel has come back; it would otherwise land part-way through the body below.
            time.sleep(0.3)
            self.drain()
            self.send('loadscript ' + name)
            for ln in body.splitlines():
                self.send(ln)
            self.send('endscript')
            time.sleep(0.3)
            if self.q('print(type(%s))' % name, timeout=30) != 'nil':
                loaded = True
                self.loads = attempt + 1
                break
        # RESTORED ON EVERY RETURN, including the failures: a tool that gives up on a load must not
        # also leave the instrument sitting on HOME with the app invisible. Not on a RAISE -- there
        # is no try/finally here -- so a socket error from send() or line() does leave it on HOME.
        # Harmless, because the next load goes HOME first anyway.
        if not loaded:
            self.restore_panel()
            return ['<LOAD FAILED: %s never defined after 4 attempts>' % name]
        if not run:
            self.restore_panel()
            return []
        self.send(name + '()')
        out = []
        first = True
        while True:
            ln = self.line(timeout)
            if ln is None:
                out.append('<TIMEOUT waiting for output>')
                break
            # A REFUSED RUN SAYS SO IMMEDIATELY, AND NO SENTINEL IS COMING. Without this the read
            # sat out the whole timeout afterwards -- the measured 301.3 s above is exactly that,
            # 1.3 s of refusal and 300 s of waiting. Named rather than left as a timeout, because
            # the two have different remedies: this one wants the panel sent HOME.
            if first and ln.strip() == REFUSAL_LINE:
                self.refusals += 1
                out.append(ln)
                out.append('<RUN REFUSED: the panel was not released; see load_script>')
                break
            first = False
            if ln == sentinel:
                break
            out.append(ln)
        self.restore_panel()
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
