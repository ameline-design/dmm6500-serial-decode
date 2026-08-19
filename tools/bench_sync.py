#!/usr/bin/env python3
"""ALIGNMENT AND RESTING-STATE CHECKS SHARED BY EVERY BENCH HARNESS.

A bench tool is an instrument that measures an instrument, so a tool that reports a false PASS is the
same class of defect as an app that reports a confident wrong byte -- one level up, and harder to
notice, because the only thing that would have caught it is the tool itself. This module holds the three
checks that every harness needs and that each of them previously did differently, incompletely, or not
at all.

WHY A SOCKET NEEDS A SENTINEL. `d.q()` sends a statement and reads ONE line. It cannot tell whether that
line is the answer to THIS statement or a leftover from the last conversation -- and every stale line is
itself a plausible answer. `sdec ~= nil` replying with the PREVIOUS command's output reads as a healthy
app being absent, or an absent one being healthy. `drain()` is not enough: it discards bytes already
ARRIVED, and the line in flight arrives a millisecond later. Only a value the instrument echoes back can
prove alignment.

THE INSTRUMENT TALKS WITHOUT BEING ASKED, and every line-reading harness has to expect it.
`localnode.showevents = eventlog.SEV_ERROR` makes error-severity events print onto the CONTROL socket as
they occur -- verified: posting one yields `1005, User: ...` with nothing having requested it. Several
harnesses set it and none restores it, so the setting persists on the instrument across runs and across
tools. Consequences, both of which have happened:

  * A reader that matches lines by PREFIX and loops on anything else can be held open indefinitely, with
    each unexpected line restarting its read timeout. One soak lap ran 5.5 HOURS this way and then
    reported nothing, having discarded the very lines that said why.
  * A reader that takes "the next line" as its answer can be handed an event message instead.

So: tagged() skips every line that is not its own nonce, and any harness that loops on lines needs BOTH a
wall-clock deadline (a per-read timeout is not a bound on the call) and somewhere to keep the unsolicited
lines, because they are the evidence.

WHY A NONCE PER MEASUREMENT, not just at connect. A point that times out on the host while the
instrument is still working leaves its reply in the stream. The next point then reads the PREVIOUS
point's result and scores it against the current stimulus -- a false PASS or a false FAIL with no
symptom. Tagging every result with a value only this call knows makes that impossible rather than
unlikely.

WHY A RESTING-STATE CHECK. `sdec.start()` builds the display objects once per power cycle and the
firmware does not fully return the pool, so every harness runs with --no-start/--reuse and INHERITS
whatever the last client left. Three inherited things are known to produce false verdicts:

  * capmode left in a streaming mode -- the first point runs as a recording, needs a locked baud rate,
    and a perfectly good vector is filed as "no bytes decoded".
  * a previous run's ck_tot/res still set -- the first point reports the PREVIOUS recording's bytes.
  * strm_stopped_by_press armed -- the queued-press absorb eats the first Capture and the panel keeps
    the old result. Worse, the absorb's age lives in the instrument's ONE global timer, so any harness
    that calls timer.cleartime() to time a press makes a stale arm look current. See disarm_absorb().

AND WHY IT REFUSES RATHER THAN REPAIRS when something is genuinely in flight: a live recording or an
open decode job means another client owns this instrument, and steering it gives a measurement of a
setup this tool just corrupted.
"""
import binascii
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# A RANDOM SESSION TOKEN, not just the pid. A recycled pid resets the counter to zero, so a fresh process
# would reuse `Q<pid>_1` -- and if the instrument still holds output from the PREVIOUS process with that
# pid (a host reboot while the DMM stays powered), that stale line matches the new process's first query
# and is accepted as its answer. One urandom token at import closes it; per-call randomness is not needed
# because the counter already separates calls within a run.
_SESSION = binascii.hexlify(os.urandom(3)).decode()
_SEQ = [0]


def nonce(prefix='bs'):
    """A token unique to this call, and to this process across reboots."""
    _SEQ[0] += 1
    return '%s%s_%d' % (prefix, _SESSION, _SEQ[0])


# ESCAPE THE DELIMITERS ON THE INSTRUMENT, DECODE ON THE HOST. Values read back can be arbitrary text --
# sdec.lasterr and flog_why carry error messages -- and two characters in one would break the protocol:
# a '|' shifts every later field, and a NEWLINE ends the line and starts what looks like a fresh one. The
# second is the serious one: since a caller might read a value that itself contains a plausible reply
# line, an unescaped newline lets a VALUE forge a whole tagged answer. Only four characters need it, so
# the wire stays readable.
# A POSITIVE CLASS -- everything NOT plainly safe is escaped -- rather than a list of the characters that
# are dangerous. Naming the dangerous ones needs '\13' and '\10' inside a Lua pattern inside a Python
# string, and that escaping silently did not match: a value containing a NEWLINE came back as two lines,
# with the pipe correctly escaped and the newline not. A negated %w class has no control characters to
# escape and cannot be got wrong the same way. Over-escaping is harmless -- it round-trips -- and the
# common values (model names, versions, 'frame', 'true', numbers) contain nothing outside the safe set,
# so the wire stays readable.
_ENC = ("local __bse = function(v) return (string.gsub(tostring(v), '[^%w%.%-%+ :;,/=%(%)]', "
        "function(c) return string.format('~%02X', string.byte(c)) end)) end ")


def _dec(v):
    """Undo _ENC's escaping."""
    return re.sub(r'~([0-9A-Fa-f]{2})', lambda m: chr(int(m.group(1), 16)), v)


def resync(d, tries=60, timeout=10):
    """Discard everything queued until a sentinel comes back. -> True if the stream is aligned.

    Cheap insurance and the only reliable kind: one print of a value nothing else could produce, then
    read until it appears. Anything read before it belonged to a previous conversation.
    """
    tag = nonce('SYNC')
    d.drain()
    d.send('print(%r)' % tag)
    for _ in range(tries):
        ln = d.line(timeout)
        if ln is None:
            return False
        # EXACT, not a substring: a line that merely CONTAINS the tag is contaminated output, and
        # accepting it would call a stream aligned when something else is interleaved with it.
        if ln == tag:
            return True
    return False


def tagged(d, expr_pairs, timeout=30, tries=3):
    """Read several instrument values in ONE reply, proved to be this call's. -> dict or None.

    expr_pairs is [(name, lua_expression), ...]. The reply is one line, so the values are consistent
    with each other -- successive q() calls can straddle a state change and describe a machine that was
    never in either state. The nonce is echoed inside the line, so a stale line cannot be mistaken for
    the answer, and a mismatched line is skipped rather than parsed.
    """
    tag = nonce('Q')
    names = [n for n, _ in expr_pairs]
    fmt = '|'.join(['%s'] * (len(expr_pairs) + 1))
    args = ['%r' % tag] + ['__bse(%s)' % e for _, e in expr_pairs]
    stmt = _ENC + "print(string.format('QQ %s', %s))" % (fmt, ', '.join(args))
    for _ in range(tries):
        d.drain()
        d.send(stmt)
        for _ in range(40):
            ln = d.line(timeout)
            if ln is None:
                break
            if not ln.startswith('QQ '):
                continue
            f = ln[3:].split('|')
            if not f or f[0] != tag:
                continue                      # a previous call's answer; keep reading
            # THE EXACT FIELD COUNT, not padded-or-truncated. Padding a short reply invents '?' values
            # that read as real answers, and truncating a long one hides that the line was malformed --
            # either way a corrupted reply is handed back as data. A wrong count means this line is not a
            # valid answer, so keep looking for one that is.
            if len(f) != len(names) + 1:
                continue
            return dict(zip(names, [_dec(v) for v in f[1:]]))
    return None


# The Lua expressions that say whether a run is in flight. One place, so every harness asks the same
# question -- they had each invented their own subset, and the subsets disagreed.
STATE_EXPRS = [
    ('capmode', 'sdec.capmode'),
    ('recording', 'sdec.strm_recording'),
    ('job', 'sdec.ck_job ~= nil'),
    ('running', 'sdec.ck_running'),
    ('inflight', 'sdec.strm_inflight'),
    ('built', 'sdec.built'),
]


def read_state(d, timeout=30):
    """The app's resting state, in one tagged reply. -> dict or None if it cannot be read."""
    return tagged(d, STATE_EXPRS, timeout=timeout)


def is_live(st):
    """True if a run is genuinely in flight -> this tool must not touch the instrument."""
    return any(st.get(k) == 'true' for k in ('recording', 'job', 'running', 'inflight'))


def disarm_absorb(d, timeout=20):
    """Clear the queued-press absorb and any latched stop. -> True if it took.

    MANDATORY BEFORE ANY HARNESS THAT CALLS timer.cleartime(). strm_stopped_by_press is only a boolean
    meaning "armed"; strm_absorb_arm() records WHEN by clearing the instrument's single global timer. So
    resetting that timer to time a press makes an arm from minutes ago look like it happened a moment
    ago -- strm_absorb_due() then returns true, sdec.capture() RETURNS WITHOUT CAPTURING, and the
    harness scores the panel's previous result as this point's answer.

    The absorb exists to stop an operator's queued press being honoured as a new capture. A host-driven
    run has no finger and no queued press, so disarming it is correct rather than merely convenient.
    """
    return d.exec('sdec.strm_stopped_by_press = nil sdec.ck_stop = false', timeout=timeout)


def preflight(d, who, need_built=True, timeout=30):
    """Align the socket, refuse a live run, and put a resting app back in FRAME. -> dict.

    Returns the state dict on success. Raises SystemExit with a reason on anything it will not proceed
    through -- a harness that continues past this has no idea what it is measuring, and a refusal with a
    reason is worth more than a number that might be about the wrong thing.
    """
    if not resync(d):
        raise SystemExit('%s REFUSING: the instrument will not resync -- the reply stream is stale. '
                         'Another client may be connected, or a previous run was killed mid-command.'
                         % who)
    st = read_state(d, timeout=timeout)
    if st is None:
        raise SystemExit('%s REFUSING: could not read the app state in one tagged reply.' % who)
    if need_built and st.get('built') != 'true':
        raise SystemExit('%s REFUSING: no built app on the panel (built=%r). Load it with '
                         'tools/run_app.py, or drop --no-start/--reuse.' % (who, st.get('built')))
    if is_live(st):
        raise SystemExit('%s REFUSING: a run is in flight (recording=%s job=%s running=%s inflight=%s). '
                         'Another client owns this instrument, or a previous run was killed mid-flight. '
                         'Nothing has been touched.'
                         % (who, st.get('recording'), st.get('job'), st.get('running'),
                            st.get('inflight')))
    # mode_exit() FIRST, THEN THE ASSIGNMENT -- both, in that order, and neither alone.
    #
    # mode_exit() is what SETTLES the instrument: it stops the acquisition, closes any open decode job
    # and flushes the log. Assigning capmode alone would change the app's idea of the mode and leave
    # all of that behind it, which is why this used to be "through mode_exit(), never by assigning".
    #
    # BUT mode_exit() NO LONGER CHANGES THE MODE. As of 2026-08-19 it is a flush and nothing else: a
    # recording that finishes leaves the operator in the mode they chose, because with the capture mode
    # in the title bar a self-changing mode reads as the app deciding something. So the unwind settles
    # the hardware and the assignment states the precondition this function exists to guarantee --
    # without it the verification below refuses every time the app is resting in a recording mode, which
    # is every soak lap after a `payloads` point.
    if st.get('capmode') != 'frame':
        print('  %s: app was resting in %r -- unwinding through mode_exit()' % (who, st.get('capmode')))
        # `who` IS NOT INTERPOLATED RAW. Every current caller passes a fixed literal, but this is Lua
        # SOURCE being built by string substitution: one quote in a caller-supplied name would change the
        # statement rather than the message inside it. Reduced to a safe alphabet instead of trusted.
        safe = re.sub(r'[^A-Za-z0-9_ -]', '', str(who))[:40] or 'preflight'
        if not d.exec("pcall(function() sdec.mode_exit('%s preflight') end) "
                      "sdec.capmode = 'frame'" % safe, timeout=60):
            raise SystemExit('%s REFUSING: mode_exit() did not complete.' % who)
    # THE PREVIOUS RUN'S RESULT GOES TOO. ck_tot survives a mode change, and while it is set the status
    # row shows the STREAM summary rather than the frame row -- so the first point can report the
    # previous recording's byte count and filename as its own.
    if not d.exec('sdec.ck_tot, sdec.ck_nbytes, sdec.ck_endwhy = nil, nil, nil '
                  'sdec.fc_win, sdec.fc_bytes, sdec.fc_end, sdec.fc_secs = nil, nil, nil, nil '
                  'pcall(function() sdec.clear_result() end)', timeout=timeout):
        raise SystemExit('%s REFUSING: could not clear the previous result.' % who)
    if not disarm_absorb(d, timeout=timeout):
        raise SystemExit('%s REFUSING: could not disarm the queued-press absorb.' % who)
    # VERIFIED, not assumed. Every step above is a pcall on the instrument and could have failed
    # quietly; this is the only line that proves the state the rest of the run depends on.
    st2 = read_state(d, timeout=timeout)
    if st2 is None or st2.get('capmode') != 'frame' or is_live(st2):
        raise SystemExit('%s REFUSING: the app is not at rest in FRAME after cleanup (%r).' % (who, st2))
    return st2

def sdg_alive(ip=None, port=None, timeout=4):
    """Is the generator's SCPI service answering? -> (True, idn) or (False, reason).

    A SEPARATE, SHORT-TIMEOUT PROBE, because the SDG2122X's LAN service wedges while its network stack
    stays up: it PINGS normally and REFUSES the SCPI port, or accepts a connection and never answers.
    Observed on this bench, and the reason tools/instruments.py warns against repeated large uploads.

    Every harness should ask this BEFORE doing anything else, so a wedged generator produces one clear
    sentence naming the remedy (power-cycle it) rather than a traceback from whichever call happened to
    touch it first -- or worse, a run that treats the last waveform still playing as the stimulus it
    thinks it selected.
    """
    import socket
    if ip is None or port is None:
        try:
            from siglent import SDG_IP, SDG_PORT
            ip = ip or SDG_IP
            port = port or SDG_PORT
        except Exception as e:
            return False, 'cannot read the generator address: %s' % e
    try:
        s = socket.create_connection((ip, port), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(b'*IDN?\n')
        r = s.recv(200)
        s.close()
        if not r:
            return False, 'the SCPI port accepted a connection and answered nothing'
        return True, r.decode(errors='replace').strip()
    except ConnectionRefusedError:
        return False, ('the SCPI port is REFUSED at %s:%s while the host still pings -- the LAN service '
                       'has wedged. Power-cycle the generator.' % (ip, port))
    except socket.timeout:
        return False, ('the SCPI port at %s:%s accepted nothing within %g s -- the LAN service has '
                       'wedged. Power-cycle the generator.' % (ip, port, timeout))
    except Exception as e:
        return False, '%s: %s' % (type(e).__name__, e)


def require_sdg(who):
    """Refuse the run with a remedy if the generator is not answering. -> the IDN string."""
    ok, why = sdg_alive()
    if not ok:
        raise SystemExit('%s REFUSING: %s' % (who, why))
    return why
