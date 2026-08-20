#!/usr/bin/env python3
"""SCPI driver for the Siglent SDS1204X-E oscilloscope -- the bench's independent oracle.

WHY THIS FILE MATTERS MORE THAN ITS SIZE SUGGESTS

Every offline result in this project is self-consistent by construction: our
generator makes the stimulus and our decoder reads it, so a passing test proves
the two agree with each other. It cannot prove either is right. A different
vendor's decoder looking at the SAME physical signal at the SAME instant is a
genuine second opinion, and this scope has UART, LIN and CAN decoders as standard
on this unit.

It also collapses the triage of a Phase 4 failure from three causes to one. A
wrong decode can mean the stimulus was not what we asked for, the DMM's front end
mangled it, or our decoder is wrong. With the scope on the same coax the first is
answered immediately and the third becomes cheap -- which probably saves more
bench time than everything else in the plan.

READING RESULTS: the SDS1000X-E family does not expose decode LIST contents over
SCPI -- DCPA? returns the decode settings, not the decoded bytes. So the decode
list is read from a screenshot. That is not a workaround, it is the supported
route, and it works unattended because the screenshot can be looked at directly.

Two independent readbacks are therefore available and they answer different
questions:
  screenshot()  -> the scope's own DECODE of the signal (an oracle for bytes)
  waveform()    -> the scope's own SAMPLES of the signal at 1 GSa/s against the
                   DMM's 1 MSa/s (an oracle for the SIGNAL, which is what
                   separates "the front end mangled it" from "we decoded it wrong")

Offline use: transport='dry' records the command stream and opens no socket.
"""
import argparse
import os
import socket
import struct
import sys
import time

try:
    from instruments import SCOPE_IP, SCPI_PORT, SCOPE_DEEP_CHANNELS, verify
except ImportError:
    SCOPE_IP, SCPI_PORT, SCOPE_DEEP_CHANNELS = '', 5025, (1, 3)
    verify = None


class Scope:
    def __init__(self, ip=None, port=SCPI_PORT, timeout=15, transport='socket',
                 settle=0.10):
        self.log = []
        self.dry = (transport == 'dry')
        self.settle = settle
        self.s = None
        if not self.dry:
            ip = ip or SCOPE_IP
            if not ip:
                raise RuntimeError(
                    'the scope address is not known yet -- set SCOPE_IP in the '
                    'environment or tools/instruments.py. Use transport="dry" '
                    'to check the command stream without it.')
            self.s = socket.socket()
            self.s.settimeout(timeout)
            self.s.connect((ip, port))
            # Bare replies. Without this every response is prefixed with the
            # command that produced it ("C1:VDIV 1.00E+00"), which every parser
            # then has to strip -- and one of them eventually will not.
            self.write('CHDR OFF')

    # ---------------- transport ----------------
    def write(self, cmd):
        self.log.append(cmd)
        if self.dry:
            return
        self.s.sendall((cmd + '\n').encode())
        time.sleep(self.settle)

    def query(self, cmd, timeout=15):
        """One query, one reply -- with the socket DRAINED first.

        Without the drain the replies walk one behind the questions the moment anything leaves an
        unread byte on the socket, and the symptom is not an error: 'TRMD?' answers '1.00E+09' (the
        previous SARA? reply) and 'C4:VDIV?' answers 'STOP'. Both parse as strings, one parses as a
        float, and a measurement built on them is confidently wrong. Cost is one non-blocking read.
        """
        self.log.append(cmd)
        if self.dry:
            return '<dry>'
        self._drain()
        self.s.settimeout(timeout)
        self.s.sendall((cmd + '\n').encode())
        return self._recv_text(timeout).strip()

    def _drain(self):
        """Discard anything already waiting. Returns what it threw away, for a caller that cares."""
        junk = b''
        self.s.settimeout(0.05)
        while True:
            try:
                b = self.s.recv(65536)
            except Exception:
                break
            if not b:
                break
            junk += b
        return junk

    def setq(self, cmd, query, want, tol=1e-9):
        """Write cmd, then READ BACK `query` and check it took. -> the value read.

        THE SCOPE CLAMPS SILENTLY. 'TDIV 200US' left the timebase at 1.00E-09 -- its minimum -- and
        'C4:VDIV 1V' left 5.00E-04, with no error and no event: the suffix forms in this class's own
        helpers are not accepted by this firmware, and a measurement then runs at a setting nobody
        chose. Exponential notation ('2.00E-04') is what works. This is the house rule for both
        Siglent boxes -- write, then read back -- applied where it was missing.
        """
        self.write(cmd)
        got = self.query(query)
        try:
            ok = abs(float(got) - float(want)) <= tol * max(1.0, abs(float(want)))
        except (TypeError, ValueError):
            ok = str(got).strip().upper() == str(want).strip().upper()
        if not ok:
            raise RuntimeError('%r did not take: %s reads %r, wanted %r (the scope clamps silently '
                               '-- use exponential notation)' % (cmd, query, got, want))
        return got

    def _recv_text(self, timeout):
        chunks = []
        self.s.settimeout(timeout)
        while True:
            try:
                b = self.s.recv(65536)
            except socket.timeout:
                break
            if not b:
                break
            chunks.append(b)
            if b.endswith(b'\n'):
                break
        return b''.join(chunks).decode(errors='replace')

    def _recv_exact(self, n, timeout=30):
        """Read n bytes. Screen dumps and waveform blocks are megabyte-scale and
        arrive in many TCP segments, so a single recv() returns a fraction of
        them -- which reads as a corrupt image rather than a short read."""
        out = bytearray()
        self.s.settimeout(timeout)
        while len(out) < n:
            b = self.s.recv(min(65536, n - len(out)))
            if not b:
                break
            out.extend(b)
        return bytes(out)

    def idn(self):
        return self.query('*IDN?')

    # ---------------- acquisition ----------------
    def channel(self, ch, vdiv=None, ofst=None, coupling='D1', on=True):
        """coupling: D1 = DC 1x, A1 = AC 1x -- Siglent's spelling of probe+coupling."""
        self.write(f'C{ch}:TRA {"ON" if on else "OFF"}')
        if vdiv is not None:
            self.write(f'C{ch}:VDIV {vdiv}')
        if ofst is not None:
            self.write(f'C{ch}:OFST {ofst}')
        self.write(f'C{ch}:CPL {coupling}')

    def timebase(self, tdiv):
        self.write(f'TDIV {tdiv}')

    def memory(self, size='14M'):
        """Capture depth. 14 Mpt is the maximum on this model, and it is only
        available when one channel of each PAIR is used -- CH1 and CH3, not CH1
        and CH2, because each pair shares capture memory. Using CH2 for the sync
        marker would silently halve the depth on CH1."""
        self.write(f'MSIZ {size}')

    def single(self):
        """Arm for one acquisition. SINGLE rather than AUTO so the screenshot and
        any waveform readback describe the SAME capture -- in AUTO the display
        advances between the two, so they describe different events."""
        self.write('TRMD SINGLE')

    # THE SCOPE CAPS HOW MANY SERIAL FRAMES IT WILL DECODE PER ACQUISITION.
    # Firmware 1.3.26 added the popup "Decoding to maximum frame number
    # limitation!" for exactly this. It is announced on screen rather than in a
    # status bit, so it lands on a screenshot and is detectable -- but only by
    # looking for it. The 200-frame Page200B (v46) is the one expected to trip it.
    #
    # Consequences: prefer SHORT vectors as oracles (v41's 13 bytes, not v46's
    # 200), and never read "the scope decoded fewer frames than the DMM" as the
    # DMM inventing bytes until that popup has been ruled out.
    FRAME_CAP_WARNING = 'Decoding to maximum frame number limitation'

    def stop(self):
        self.write('STOP')

    def trigger_edge(self, ch, level, slope='POS'):
        """Edge trigger on a channel.

        ENABLE THE CHANNEL FIRST. Firmware before 1.3.28 raises an "SCPI
        instruction configuration exception when inactive channel is set as
        trigger source", and the scope is currently on 1.3.27. This matters
        because triggering on CH4 -- the DMM's capture-window marker -- is the
        natural choice for comparing the two instruments' views of one event, and
        CH4 is not on by default. channel() before trigger_edge(), always.
        """
        self.write(f'TRSE EDGE,SR,C{ch},HT,OFF')
        self.write(f'C{ch}:TRLV {level}')
        self.write(f'C{ch}:TRSL {slope}')

    def sample_rate(self):
        return self.query('SARA?')

    def sample_count(self):
        return self.query('SANU? C1')

    # ---------------- serial decode ----------------
    # Syntax per the SDS1000X-E programming guide. This unit has all three
    # decoders unlocked.
    #
    # FEED THE THRESHOLD FROM THE DMM. Passing the scope the DMM's own computed
    # sdec.thr is what makes a disagreement diagnosable: if both instruments use
    # the same threshold and disagree, the fault is in framing; if the scope
    # agrees with the payload at its own threshold but not at ours, the fault is
    # in the threshold. Left on the scope's default, the two are confounded.

    # DECODE RESULTS HAVE NO SCPI QUERY. Confirmed, not assumed: the programming
    # guide's entire DECODE subsystem is DCST, DCPA, B<n>:DCIC, B<n>:DCSP,
    # B<n>:DCUT, B<n>:DCCN and B<n>:DCLN -- all of them setters and queries of
    # SETTINGS. Nothing returns decoded bytes. So the screenshot is the supported
    # route to the decode list, not a workaround, and DIS,ON matters as much as
    # the protocol parameters: an undisplayed bus decodes to nothing readable.
    #
    # Availability table: decode is "yes" for SDS1000X-E. Two buses only, B1/B2.

    def decode_on(self, on=True):
        self.write(f'DCST {"ON" if on else "OFF"}')

    def decode_display(self, bus=1, fmt='HEX', lines=7, slot=None):
        """Show the decode LIST, which is the part a screenshot can be read from.

        lines is LSNM, documented range 1 to 7 -- so ONE screenshot shows at most
        seven rows. A 13-byte payload therefore needs decode_scroll() plus a
        second shot; see there.

        slot defaults to the bus number: LIST D1 is bus 1's list and D2 is bus 2's,
        so pairing them is almost always what is meant.
        """
        if bus not in (1, 2):
            raise ValueError('the SDS1000X-E has two decode buses, B1 and B2')
        if not (1 <= lines <= 7):
            raise ValueError('LSNM is documented as 1 to 7 lines')
        if slot is None:
            slot = bus
        self.write(f'DCPA BUS,B{bus},LIST,D{slot},FOMT,{fmt},LSNM,{lines}')

    def decode_scroll(self, row):
        """Scroll the decode list to a given row (LSSC).

        The list shows at most 7 rows, so reading a longer payload means
        scrolling and taking another screenshot. Without this, a 13-byte vector
        looks like a 7-byte disagreement -- the most misleading possible result,
        because it presents as data loss rather than as a display limit.
        """
        self.write(f'DCPA LSSC,{row}')

    def verify_decode(self, bus, baud, what, kind='DCUT'):
        """Read the decode bus back and confirm the baud rate actually took.

        This is the write-then-read-back rule applied where it earns the most: a
        baud rate the firmware rejects as out of range is not reported anywhere,
        the bus simply decodes garbage -- which presents as the scope DISAGREEING
        WITH THE DMM, i.e. as evidence against our decoder, when in fact the
        oracle was never configured. That is the single most misleading failure
        this file can produce.

        It also settles the manual's LIN self-contradiction empirically: whatever
        the instrument echoes is the truth.

        Non-fatal by design -- it warns rather than raises, because a decode
        readback whose FORMAT differs from expectations should not abort a run
        that is otherwise fine. The warning is what stops a bad oracle being
        trusted silently.
        """
        if self.dry or verify is None:
            return True
        got = self.query(f'B{bus}:{kind}?')
        if str(baud) not in got:
            print(f'WARNING: {what} baud {baud} does not appear in the readback '
                  f'"{got}" -- the firmware may have rejected it as out of range. '
                  f'A misconfigured oracle disagrees with the DMM and looks like '
                  f'a DMM defect. Believe this reply over the manual.',
                  file=sys.stderr)
            return False
        return True

    def decode_uart(self, ch=1, threshold=1.65, baud=9600, nbits=8,
                    parity='NONE', stop=1, polarity='HIGH', bitorder='LSB',
                    bus=1):
        """UART. polarity HIGH = idle high, the ordinary TTL sense.

        Parameter names and value sets are from the guide's DCUT table:
        PAR is {NONE,EVEN,ODD} -- NOT "NO" -- STOP is {1,1.5,2}, POL is
        {LOW,HIGH}, BIT is {MSB,LSB}, BAUD is 300 to 50000000.

        DLEN is 5 to 8. The DMM's decoder searches 5..9 in its any-width mode, so
        a 9-bit format is one the scope CANNOT corroborate -- worth remembering
        before treating a 9-bit disagreement as a DMM defect.

        Thresholds carry an explicit V. The guide says the unit defaults to volts,
        but it also says "the range of value is related to the vertical scale of
        the source" -- so a threshold well outside the current V/div may be
        silently clamped. Set the channel scale before the threshold.
        """
        if parity not in ('NONE', 'EVEN', 'ODD'):
            raise ValueError("PAR must be NONE, EVEN or ODD (not 'NO')")
        self.write(f'B{bus}:DCUT DIS,ON,RX,C{ch},RXT,{threshold}V,BAUD,{baud},'
                   f'DLEN,{nbits},PAR,{parity},STOP,{stop},POL,{polarity},'
                   f'BIT,{bitorder}')
        self.verify_decode(bus, baud, f'UART bus {bus}')

    def decode_lin(self, ch=1, threshold=3.0, baud=9600, bus=1):
        """LIN. THE LEAST TRUSTWORTHY CALL IN THIS FILE, and the guide is why.

        Its DCLN table gives BAUD as "300 to 2000", which is impossible for LIN
        (1-20 kbit/s in practice). Its own worked example for the LIN command
        then reads:

            B1:DCCN DIS,ON,SRC,D0,BAUD,9600

        -- which names DCCN, the CAN command, inside the DCLN section, and uses
        9600, a value the table it sits under forbids. So the section contradicts
        itself, and the contradiction is mildly reassuring: the example suggests
        the real ceiling is at least 9600 and "2000" is a typo for 20000.

        Hence the default here is 9600 rather than 19200 -- of the three LIN
        vectors, v63 is at 9600 and is the one most likely to be accepted, so try
        it FIRST and treat a rejection at 19200 as a scope limit rather than a
        stimulus problem.

        If DCLN is unusable at any rate, fall back to decode_uart() at 8N1: LIN is
        8N1 on the wire, so a UART decode still corroborates every byte including
        the break's framing error, and only the frame-layer interpretation
        (PID parity, checksum style) is lost -- which is the part our own tests
        already cover most thoroughly.
        """
        self.write(f'B{bus}:DCLN DIS,ON,SRC,C{ch},SRCT,{threshold}V,BAUD,{baud}')
        # The reply settles the "300 to 2000" contradiction empirically: whatever
        # the instrument echoes is the truth, whatever the manual says.
        self.verify_decode(bus, baud, f'LIN bus {bus}', kind='DCLN')

    def decode_can(self, ch=1, threshold=2.5, baud=500000, bus=1):
        """CAN, single-ended off one line. Present and unlocked on this unit,
        which is why the testability argument for deferring a CAN decoder in the
        app is weaker than it was.

        The parameter set is NOT symmetric with UART/LIN, which is easy to get
        wrong: SRC does not take a channel. Per the DCCN table, the channel goes
        in CANH (with CANHT as its threshold) and SRC selects which line to decode
        from, {CAN_H, CAN_L, SUB_L}. BAUD is 5000 to 1000000.
        """
        self.write(f'B{bus}:DCCN DIS,ON,CANH,C{ch},CANHT,{threshold}V,'
                   f'SRC,CAN_H,BAUD,{baud}')

    # ---------------- readback ----------------
    def screenshot(self, path):
        """SCDP -> a BMP. Returns the byte count written.

        The reply is the file itself: '<bmp header><bmp screen data>' with no
        SCPI wrapper, so the length has to come from the BMP header rather than
        from a block count. Reading a fixed guess instead is how this silently
        produces a truncated image that still opens.
        """
        if self.dry:
            self.log.append('SCDP')
            return 0
        self.log.append('SCDP')
        self.s.sendall(b'SCDP\n')
        head = self._recv_exact(14, timeout=30)
        # RESYNC ON 'BM' RATHER THAN DEMANDING IT AT OFFSET ZERO.
        #
        # The SECOND SCDP of a session comes back as b'\nBMB\xb8\x0b...' -- a
        # leading newline left in the socket by the previous reply. A header check
        # at offset zero then fails on a screenshot that is perfectly good one byte
        # later, which turns "take several screenshots" into a coin toss. Skip
        # leading whitespace and top the header back up to
        # 14 bytes; anything that is still not a BMP is a real failure.
        if head[:2] != b'BM':
            stripped = head.lstrip(b'\r\n\t ')
            if stripped[:2] == b'BM' and len(stripped) < 14:
                head = stripped + self._recv_exact(14 - len(stripped), timeout=30)
            else:
                head = stripped
        if len(head) < 14 or head[:2] != b'BM':
            raise RuntimeError(f'SCDP did not return a BMP: {head[:16]!r}')
        total = struct.unpack('<I', head[2:6])[0]
        body = self._recv_exact(total - 14, timeout=60)
        data = head + body
        with open(path, 'wb') as fh:
            fh.write(data)
        if len(data) != total:
            raise RuntimeError(f'SCDP truncated: {len(data)} of {total} bytes')
        return len(data)

    def screenshot_png(self, path):
        """Same, converted to PNG, because that is what can be looked at directly."""
        bmp = path[:-4] + '.bmp' if path.endswith('.png') else path + '.bmp'
        n = self.screenshot(bmp)
        if self.dry:
            return 0
        from PIL import Image
        Image.open(bmp).save(path)
        os.remove(bmp)
        return n

    def waveform(self, ch=1, points=None):
        """The scope's own samples, as volts. THE TIEBREAKER.

        This is the readback that separates "the DMM's front end mangled the
        signal" from "our decoder is wrong" -- at 1 GSa/s against the DMM's
        1 MSa/s, it shows what the signal actually looked like between the DMM's
        samples.

        It matters more than it first appears, because the scope's DECODERS are
        not infallible: this firmware release fixes "sometimes UART decoding stop
        bit judgement error", by Siglent's own admission. So a decode
        disagreement localises the fault to one of the two decoders WITHOUT
        saying which, and resolving it by deciding whose decoder to trust is not
        resolving it at all. These samples are data rather than interpretation,
        which is what turns a standoff into an answer.

        Corollary for comparisons: byte VALUES are the strongest field to compare
        between the instruments, and FRAMING-ERROR COUNTS are the weakest -- our
        decoder declines to judge stop-bit count at all ("not observable from the
        wire") and the scope's stop-bit judgement was buggy until this release.
        Treat a framing-error disagreement as advisory.

        Reply format: 'DAT2,#9<9 ASCII digits><signed bytes>\\n\\n'. Samples are
        8-bit signed; volts = code * VDIV/25 - OFST, which is the SDS scaling
        (25 codes per division, 8 divisions of screen).
        """
        if self.dry:
            self.log.append(f'C{ch}:WF? DAT2')
            return [], {}
        if points:
            self.write(f'WFSU SP,0,NP,{points},FP,0')
        vdiv = float(self.query(f'C{ch}:VDIV?'))
        ofst = float(self.query(f'C{ch}:OFST?'))
        self.log.append(f'C{ch}:WF? DAT2')
        self.s.sendall(f'C{ch}:WF? DAT2\n'.encode())
        head = self._recv_exact(16, timeout=30)      # 'DAT2,#9' + 9 digits
        idx = head.find(b'#9')
        if idx < 0:
            raise RuntimeError(f'unexpected waveform header: {head!r}')
        n = int(head[idx + 2:idx + 11])
        got = head[idx + 11:]
        body = got + self._recv_exact(n - len(got), timeout=120)
        vals = []
        for b in body[:n]:
            c = b - 256 if b > 127 else b
            vals.append(c * vdiv / 25.0 - ofst)
        return vals, {'vdiv': vdiv, 'ofst': ofst, 'n': n,
                      'srate': self.query('SARA?')}

    def close(self):
        if self.s is not None:
            try:
                self.s.close()
            except Exception:
                pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--shot', metavar='PATH', help='write a screenshot as PNG')
    ap.add_argument('--idn', action='store_true')
    ap.add_argument('--dry', action='store_true',
                    help='print the command stream a UART decode setup produces')
    ap.add_argument('--ip', default=None)
    a = ap.parse_args()

    if a.dry:
        sc = Scope(transport='dry')
        sc.channel(1, vdiv=1.0, ofst=-1.65)
        sc.channel(3, vdiv=1.0, ofst=0)          # the SDG sync marker
        sc.memory('14M')
        sc.timebase('1MS')
        sc.trigger_edge(1, level=1.65)
        sc.decode_on(True)
        sc.decode_uart(ch=1, threshold=1.65, baud=9600)
        sc.decode_display(bus=1, fmt='HEX', lines=7)
        sc.decode_scroll(1)
        sc.single()
        sc.screenshot_png('/dev/null')
        for c in sc.log:
            print(c)
        return 0

    sc = Scope(ip=a.ip)
    if a.idn or not a.shot:
        print(sc.idn())
    if a.shot:
        n = sc.screenshot_png(a.shot)
        print(f'{n} bytes -> {a.shot}')
    sc.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
