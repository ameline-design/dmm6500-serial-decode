#!/usr/bin/env python3
"""SCPI driver for the Siglent SDG2122X arbitrary waveform generator.

Channel 1 output feeds a coax splitter to the DMM6500 front INPUT terminals and
the scope, so this produces the known test signals for both the FFT app and the
serial decoder.

Every command here was checked against SDG Programming Guide PG02-E05B and the
per-model availability tables in it -- the SDG2000X column specifically, since
SRATE, CMBN and USER-defined arbs are all absent on some siblings. Where a fact
came from the guide the section is cited, because a recollected SCPI string that
is subtly wrong wastes bench time in a way that is hard to diagnose: the
instrument accepts it and does something else.

NOTE: this driver deliberately exposes only waveform/output control. It issues no
calibration commands of any kind, on this or any other instrument.

Offline use: pass transport='dry' to record the command stream instead of opening
a socket. That is how the orchestration is verified with the hardware 300 km away
and powered down.
"""
import re
import socket
import struct
import time

try:
    from instruments import SDG_IP, SCPI_PORT, SDG_MAX_VPP, SDG_MAX_PTS, \
        SDG_MIN_SRATE, SDG_MAX_SRATE, SDG_MIN_WAVE_BYTES, SDG_MAX_WAVE_BYTES
except ImportError:      # standalone use, e.g. copied to another machine
    SDG_IP, SCPI_PORT = '10.0.1.79', 5025
    SDG_MAX_VPP, SDG_MAX_PTS = 20.0, 8388608
    SDG_MIN_SRATE, SDG_MAX_SRATE = 1e-6, 75e6
    SDG_MIN_WAVE_BYTES, SDG_MAX_WAVE_BYTES = 4, 16 * 1024 * 1024

SDG_PORT = SCPI_PORT     # kept: existing callers import this name


# ---------------------------------------------------------------------------
# THE ONE CHOKE POINT FOR WAVEFORM DATA
# ---------------------------------------------------------------------------
# A ZERO-LENGTH OR UNDERSIZED WAVEFORM BRICKS THIS GENERATOR PERMANENTLY, and a guard living inside
# write_raw() is reachable-around by three separate routes:
#
#   1. write_raw('C1:', b'WVDT WVNM,x,WAVEDATA,' + b'\x00\x00')
#      A check keyed on `'WVDT' in prefix` misses this prefix entirely, and the assembled command on
#      the wire is a perfectly valid two-byte upload.
#   2. write('C1:WVDT WVNM,x,WAVEDATA,')
#      A check in write_raw() alone leaves write() open, and this stores an EMPTY waveform -- the
#      exact reported brick -- in one line, through the ordinary public method. query() the same.
#   3. sdg_hang_repro.upload() with --kb 0
#      A raw socket, deliberately not using this driver, so no guard applied at all.
#
# So the rules are structural rather than parameter-shaped, and they live at module level so the
# raw-socket sender can call them too:
#
#   * TEXT commands (write/query) may not carry a WVDT store AT ALL. Waveform data is binary and
#     cannot survive .encode(), so a WVDT+WAVEDATA in a text command is always either a mistake or a
#     bypass. Refusing outright needs no length arithmetic and so cannot be fooled by one.
#   * write_raw() validates the PAYLOAD OBJECT -- bytes-like, even, 4..16 MiB -- unconditionally,
#     never keyed on the prefix, and additionally refuses a payload containing a WAVEDATA, marker,
#     which is how bypass 1 smuggled the real command past a length check on the wrong bytes.
#
# WHY NOT SCAN THE ASSEMBLED BYTES AND VALIDATE THE TAIL. It looks stronger and is weaker: the tail
# would have to be split off a trailing newline, and a legitimate codeword's high byte can BE 0x0A,
# so stripping it would make a valid even payload look odd and refuse a good upload. Validating the
# payload object is exact; there is nothing to parse.
SDG_WAVEDATA_MARK = b'WAVEDATA,'


def sdg_reject_text_wavedata(cmd):
    """Refuse a TEXT command that would store waveform data. -> None, or raises ValueError.

    `C1:WVDT?` is a READ and carries no data, so it is allowed; anything else naming WVDT is not.
    """
    up = cmd.upper()
    i = up.find('WVDT')
    if i < 0:
        return
    if up[i + 4:i + 5] == '?':
        return
    raise ValueError(
        'REFUSING to send %r as text: it names WVDT, which STORES a waveform. A zero-length or '
        'undersized waveform BRICKS this generator at its next power-up and it has no shell or '
        'credentials to recover through. Waveform data is binary -- use write_raw(prefix, payload), '
        'which validates the payload, or upload_arb(), which builds it.' % cmd[:80])


def sdg_check_wave_payload(payload):
    """Validate a WVDT payload object. -> len(payload), or raises ValueError.

    Module level so tools/sdg_hang_repro.py, which uses a raw socket on purpose to reproduce the
    original wedge, can enforce the same floor without going through the driver's mitigations.
    """
    if isinstance(payload, str):
        raise ValueError('REFUSING a str payload: waveform data must be bytes, and encoding it '
                         'could change its length. Pack the codewords with struct.')
    if not isinstance(payload, (bytes, bytearray, memoryview)):
        raise ValueError('REFUSING a %s payload: waveform data must be bytes-like, and an object '
                         'without a fixed length cannot be checked before it is sent.'
                         % type(payload).__name__)
    n = len(payload)
    # THE MANUAL'S RANGE, not merely "not empty": the programming guide requires SDG2000-series
    # waveform data to be 4 bytes to 16 MB. A 2-byte waveform is out of spec, and nothing says it is
    # safer than a 0-byte one -- the reported brick is the failure that got written up, not the only
    # one available.
    if not (SDG_MIN_WAVE_BYTES <= n <= SDG_MAX_WAVE_BYTES):
        raise ValueError(
            'REFUSING a %d-byte waveform: the SDG2000 series requires %d..%d bytes. A zero-length '
            'or undersized waveform BRICKS the instrument at its next power-up, and this one has no '
            'shell or credentials to recover through.'
            % (n, SDG_MIN_WAVE_BYTES, SDG_MAX_WAVE_BYTES))
    if n % 2:
        raise ValueError(
            'REFUSING a %d-byte WVDT payload: waveform data is 16-bit codewords, so an odd length '
            'means the file is truncated. Half a waveform is not a waveform.' % n)
    # COMMAND SMUGGLING. A payload holding its own WAVEDATA, marker means the caller put the command
    # in the binary half, where a length check measures the command and not the waveform. Random
    # codewords containing this exact nine-byte string is a ~1e-21 event per upload; a caller doing
    # it deliberately is bypass 1 above.
    if SDG_WAVEDATA_MARK in bytes(payload):
        raise ValueError(
            'REFUSING a payload that contains %r: the command belongs in the prefix. With it in the '
            'payload, the length checked here is the command length and the real waveform could be '
            'any size at all.' % SDG_WAVEDATA_MARK)
    return n


class SDG:
    def __init__(self, ip=SDG_IP, port=SDG_PORT, timeout=10, transport='socket',
                 settle=0.12):
        """transport='dry' records commands in self.log and opens no socket."""
        self.log = []
        self.dry = (transport == 'dry')
        self.settle = settle
        self.s = None
        if not self.dry:
            self.s = socket.socket()
            self.s.settimeout(timeout)
            self.s.connect((ip, port))

    # ---------------- transport ----------------
    def write(self, cmd):
        # BEFORE self.log, so a refused command is not recorded as sent, and before the dry-run
        # return, so transport='dry' refuses exactly what a socket would. A dry run that accepts a
        # brick-shaped command teaches the caller that it is fine.
        sdg_reject_text_wavedata(cmd)
        self.log.append(cmd)
        if self.dry:
            return
        self.s.sendall((cmd + '\n').encode())
        time.sleep(self.settle)

    def write_raw(self, prefix, payload):
        """A command whose tail is raw binary (the WVDT upload path).

        Kept separate from write() because the payload is not text and must not
        be encoded, decoded or newline-normalised on the way out.

        SETTLE IN PROPORTION TO THE PAYLOAD, which the fixed self.settle does not.
        The generator is still digesting an upload when the next command arrives: a
        flat 0.1 s is plenty for a 40-byte BSWV and nowhere near enough for 200 kB,
        so the wait scales ~1 s per 100 kB above the base settle.

        THE HAZARD IS THE NUMBER OF LARGE WRITES, NOT THEIR SIZE, and that is measured
        both ways (instruments.py carries the session log). The THIRD over-ceiling
        upload wedged 39R7 after only 533 kB in total, while a single 1.63 MB and then
        a 6.51 MB write on one power cycle -- 8.14 MB together -- left it answering and
        playing correctly. A wedge leaves it playing the loaded waveform forever while
        accepting TCP on 5024 and 5025 and answering nothing, *IDN? included; only a
        power cycle recovers it, and it has no smart plug, so it costs a human. Hence
        the rule: fewer than three over-ceiling writes between power cycles.
        """
        # A ZERO-LENGTH WAVEFORM BRICKS THIS INSTRUMENT. Reported publicly and independently: a fumbled
        # low-level SCPI upload stored an empty waveform, and the NEXT POWER-UP showed the logo for ~25 s,
        # flashed the LEDs and left the LCD blank forever. The poster recovered only because their firmware
        # was PATCHED SO THE ROOT PASSWORD HASH WAS A KNOWN VALUE, which gave them a shell over telnet
        # and let them delete the file from /usr/bin/siglent/usr/usr by hand.
        #
        # WE HAVE NO SUCH ESCAPE. This generator runs stock 2.01.01.39R7 with no telnet, so a brick here is
        # not a power-cycle away from fixed -- it is a dead instrument. And the path to it is one we walk
        # routinely: the poster power-cycled to clear a STUCK TCP STATE, which is our WVDT wedge exactly.
        # Wedge, then power-cycle, is our documented recovery, and it is also the step that detonates a bad
        # stored waveform.
        #
        # So this refuses rather than warns, and it refuses in the DRIVER rather than in one caller --
        # tools/upload_vectors.py writes WVDT through here directly and sorted payloads by size without
        # ever checking for zero.
        # THE MANUAL'S RANGE, not merely "not empty": the programming guide requires SDG2000-series waveform
        # data to be 4 bytes to 16 MB. A 2-byte waveform is out of spec, and nothing says it is safer than
        # a 0-byte one -- the reported brick is the failure that got written up, not the only one available.
        # UNCONDITIONAL, NOT KEYED ON THE PREFIX. Every caller of this method in the repo is a WVDT
        # upload -- upload_arb and upload_vectors, nothing else -- so there is no legitimate payload
        # here that is not waveform data, and keying the check on the prefix is what let
        # write_raw('C1:', b'WVDT ... WAVEDATA,' + two bytes) through.
        sdg_check_wave_payload(payload)
        # The prefix must itself be the upload command, for the same reason: if the caller has put
        # the command somewhere else, the bytes just validated are not the waveform.
        up = prefix.upper()
        if 'WVDT' not in up or 'WAVEDATA,' not in up:
            raise ValueError(
                'REFUSING %r as a write_raw prefix: this method exists only for the WVDT upload '
                'path, so the prefix must name WVDT and end the WAVEDATA, field. A prefix that does '
                'not means the command is being assembled somewhere the payload check cannot see.'
                % prefix[:80])
        self.log.append(f'{prefix}<{len(payload)} binary bytes>')
        if self.dry:
            return
        self.s.sendall(prefix.encode() + payload + b'\n')
        time.sleep(self.settle + len(payload) / 100000.0)

    # ---------------- what the generator says it stored ----------------
    def stored_wave_length(self, name, timeout=180):
        """Bytes the GENERATOR reports for a stored waveform. -> int, or None if it will not say.

        BELT AND SUSPENDERS ON THE BRICK. Every guard in this file checks what we are about to SEND.
        This checks what the instrument actually HAS, which is the one thing a sender cannot know: a
        write that reported nothing, a truncated transfer, a wedge part way through. If the answer is
        0 the file is the shape that bricks it at the next power-up, and there is a window -- the
        generator is still alive and still answering -- in which DEL_STORE_FILE can remove it.

        `WVDT? USER,<name>` per the programming guide, p.91 format 2. The reply is
            WVDT POS,<path>, WVNM, <name>, LENGTH, 300B, TYPE, 10, WAVEDATA, <binary>
        so LENGTH is a header field and this is the documented way to get it.

        IT IS A DOWNLOAD, NOT A STAT, and that has to be handled rather than ignored: the WAVEDATA
        follows in the same reply. So the whole thing is drained -- LENGTH tells us exactly how many
        binary bytes to expect, so the read is bounded and not a guess. Draining rather than closing
        early is deliberate: a half-read socket leaves the tail to be misread as the NEXT query's
        answer, and closing mid-transfer is the stuck TCP state whose cure is a power cycle, which is
        the step that detonates a bad stored waveform. At the measured 311 kB/s a 54 kB vector costs
        ~0.2 s; the five over-ceiling ones cost proportionally more, which is why the timeout is large.
        """
        if self.dry:
            self.log.append(f'WVDT? USER,{name}')
            return None
        self.log.append(f'WVDT? USER,{name}')
        self.s.settimeout(timeout)
        self.s.sendall((f'WVDT? USER,{name}' + '\n').encode())
        buf = b''
        want = None
        while True:
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if want is None:
                m = re.search(rb'LENGTH\s*,\s*(\d+)\s*B', buf, re.I)
                w = buf.upper().find(b'WAVEDATA,')
                if m is not None and w >= 0:
                    want = w + len('WAVEDATA,') + int(m.group(1))
            if want is not None and len(buf) >= want:
                break
        m = re.search(rb'LENGTH\s*,\s*(\d+)\s*B', buf, re.I)
        if m is None:
            return None
        return int(m.group(1))

    def delete_stored_wave(self, name, force=False):
        """Delete a stored waveform. `DEL_STORE_FILE <name>.bin`.

        NOT IN THE PROGRAMMING GUIDE -- it appears nowhere in PG02-E05C -- but Siglent publish it in
        an application note, "How to delete files from the internal memory", 2021-12-07, which is
        written for the SDG6000X and opens "SIGLENT SDG arbitrary waveform generators". So it is a
        vendor-documented command that the manual omits, not a rumour.

        THE .bin SUFFIX IS ADDED HERE because the two commands disagree about names: STL? USER reports
        `SER_Hello_8N1` and the application note's example deletes `Test1.bin`. ARWV? has the same
        split, and select_arb already strips a trailing .bin for it.

        WILDCARDS REFUSED unless forced, and this is the sharp edge. A third-party report says the
        command takes them; `DEL_STORE_FILE SER_*` would take all 34 uploaded vectors, and replacing
        them is ~900 kB of WVDT writes, which is the activity that WEDGES this generator's LAN
        service. A convenience that can cost an hour and a power cycle is not a convenience.
        """
        if not force and any(c in name for c in '*?'):
            raise ValueError(
                'REFUSING to delete %r: it contains a wildcard. DEL_STORE_FILE is reported to expand '
                'them, so this could remove every stored vector, and re-uploading is the WVDT traffic '
                'that wedges the LAN service. Pass force=True if that is genuinely what you want.'
                % name)
        fn = name if name.lower().endswith('.bin') else name + '.bin'
        self.write(f'DEL_STORE_FILE {fn}')
        return fn

    def query(self, cmd, timeout=6):
        # query() sends before it reads, so it is a write path too and needs the same refusal.
        sdg_reject_text_wavedata(cmd)
        self.log.append(cmd)
        if self.dry:
            return '<dry>'
        self.s.settimeout(timeout)
        self.s.sendall((cmd + '\n').encode())
        try:
            return self.s.recv(8192).decode(errors='replace').strip()
        except socket.timeout:
            return '<timeout>'

    def idn(self):
        return self.query('*IDN?')

    # ---------------- basic waveforms ----------------
    def sine(self, freq_hz, ampl_vpp, offset_v=0.0, ch=1, phase_deg=0.0):
        """Configure a channel for a sine wave. Amplitude is peak-to-peak volts."""
        self._check_vpp(ampl_vpp)
        self.write(f'C{ch}:BSWV WVTP,SINE,FRQ,{freq_hz},AMP,{ampl_vpp},'
                   f'OFST,{offset_v},PHSE,{phase_deg}')

    def square(self, freq_hz, ampl_vpp, offset_v=0.0, duty=50.0, ch=1):
        self._check_vpp(ampl_vpp)
        self.write(f'C{ch}:BSWV WVTP,SQUARE,FRQ,{freq_hz},AMP,{ampl_vpp},'
                   f'OFST,{offset_v},DUTY,{duty}')

    def output(self, on=True, ch=1, load='HZ'):
        """Enable/disable a channel output. load='HZ' suits the DMM's 10 MOhm input."""
        self.write(f'C{ch}:OUTP {"ON" if on else "OFF"},LOAD,{load}')

    def state(self, ch=1):
        return {'bswv': self.query(f'C{ch}:BSWV?'),
                'outp': self.query(f'C{ch}:OUTP?'),
                'srate': self.query(f'C{ch}:SRATE?'),
                'arwv': self.query(f'C{ch}:ARWV?'),
                'cmbn': self.query(f'C{ch}:CMBN?')}

    # ---------------- arbitrary waveforms ----------------
    # Guide section 4.1: a .bin file is raw codewords, range -32768..32767, no
    # header, little-endian 16-bit two's complement (the byte order is stated in
    # the 5.1.3 example's own comment). "When the machine imports the file, it
    # maintains the current amplitude, frequency and offset information, and
    # directly converts each codeword value into voltage output."
    #
    # THAT LAST SENTENCE IS THE TRAP. The file carries shape only. Selecting a
    # waveform does NOT set its amplitude, so an arb loaded while AMP is left
    # from a previous step plays at the wrong logic levels and every threshold
    # result from it is meaningless. Hence load_arb_file() requires amp_vpp.

    def truearb(self, srate_sa_s, ch=1):
        """TrueArb at an explicit sample rate. Guide section 3.40.

        NOT DDS. DDS holds the DAC clock fixed and steps a phase accumulator, so
        it resamples the stored points -- which is actively wrong when the thing
        being measured is sub-sample edge timing. In TrueArb the rate is set
        directly in Sa/s, so there is also no f = fs/N arithmetic to get wrong.

        INTER (interpolation) is SDG6000X and up; on the SDG2000X there is no
        interpolation control, which is fine -- zero-order hold is what a
        sampled logic waveform wants anyway.
        """
        if not (SDG_MIN_SRATE <= srate_sa_s <= SDG_MAX_SRATE):
            raise ValueError(f'sample rate {srate_sa_s} outside the TrueArb '
                             f'range {SDG_MIN_SRATE}..{SDG_MAX_SRATE} Sa/s')
        self.write(f'C{ch}:SRATE MODE,TARB')
        self.write(f'C{ch}:SRATE VALUE,{srate_sa_s:.6f}')

    def assert_truearb(self, ch=1):
        """Confirm the channel is REALLY in TrueArb after everything else was set.

        Neither manual states whether ARWV preserves the SRATE mode. A silent fall
        back to DDS would resample the stored points and therefore corrupt
        sub-sample edge timing -- the one thing this project measures -- with
        nothing on the panel to say so. So it is checked rather than assumed, on
        every load; one query is cheap against that.

        The related worry about BSWV FRQ turned out to be weaker than it looked:
        the user manual lists a TrueArb channel's parameters as "sampling
        rate/frequency, amplitude/high level, offset/low level and phase", i.e.
        frequency is an ALTERNATE VIEW of sample rate in TrueArb (f = srate/N),
        not a DDS-only parameter. Setting it is therefore probably harmless. This
        code still sets SRATE VALUE rather than FRQ, because the sample rate is
        the quantity the vectors are defined in and converting through N is an
        arithmetic step with nothing to gain.

        A TIMEOUT IS NOT A WRONG ANSWER, so it is retried rather than raised on.
        Measured: after a 178 kB WVDT upload the generator stops
        answering queries for a moment, and the first SRATE? came back
        "<timeout>". Treating that as "not in TrueArb" aborted a sweep over a
        channel that was correctly configured -- a false alarm from the very check
        that exists to prevent silent misconfiguration, which is the way to lose
        trust in it. Three tries, half a second apart; a reply that ARRIVES and
        says the wrong thing still raises immediately, because that is the real
        failure this guards against.
        """
        if self.dry:
            return True
        r = ''
        for attempt in range(3):
            r = self.query(f'C{ch}:SRATE?')
            if r and '<timeout>' not in r.lower():
                break
            time.sleep(0.5)
        if 'TARB' not in r.upper():
            raise RuntimeError(
                f'C{ch} is not in TrueArb after loading -- got "{r}" on 3 tries. '
                f'DDS would resample the points and silently corrupt edge '
                f'timing. Set SRATE MODE,TARB after ARWV rather than before, and '
                f'do not set BSWV FRQ on this channel.')
        return True

    def load_arb_file(self, filename, amp_vpp, srate_sa_s, offset_v=0.0,
                      store='U-disk0', ch=1):
        """Select a waveform file already on the instrument and set it up to play.

        store='U-disk0' plays straight off the USB key -- guide section 3.9.1
        lists C1:ARWV NAME,"U-disk0/wave1.bin" as a supported form, so there is
        no need to copy files into internal flash one at a time. 'Local' is
        internal storage if that ever becomes necessary.

        amp_vpp is required, not defaulted, for the reason above.
        """
        self._check_vpp(amp_vpp)
        self.write(f'C{ch}:ARWV NAME,"{store}/{filename}"')
        self.write(f'C{ch}:BSWV AMP,{amp_vpp},OFST,{offset_v}')
        # TrueArb LAST, then verified: if ARWV or BSWV resets the mode -- which the
        # guide does not say either way -- setting it first would be silently undone.
        self.truearb(srate_sa_s, ch=ch)
        self.assert_truearb(ch=ch)

    def select_arb(self, name, amp_vpp, srate_sa_s, offset_v=0.0, ch=1):
        """Play a waveform ALREADY UPLOADED, by name. No bulk transfer.

        WHY THIS EXISTS: every large WVDT write spends part of a budget of about two
        between power cycles (see write_raw). Re-uploading the same vectors each run
        spends it for no new information, since they are already stored and only need
        selecting. Once each is up this path is cheap and never touches the failure
        mode -- and because the rate comes from srate here, one stored waveform serves
        every baud rate rather than needing a render per speed.

        Same ordering discipline as load_arb_file: TrueArb last, then verified.
        """
        self._check_vpp(amp_vpp)
        self.write(f'C{ch}:ARWV NAME,{name}')
        # READ THE NAME BACK. Selecting a waveform that is not on the instrument does not fail --
        # the previous one keeps playing, so every later measurement is attributed to the wrong
        # stimulus -- twelve vectors added to a suite but never uploaded all "fail" against the
        # PREVIOUS vector's bytes. TrueArb is verified below; the name is the point of the call, so
        # it is verified here.
        # A GENEROUS READBACK TIMEOUT, because selecting a LARGE waveform is slow and a 6 s default
        # turns that into a false "did not take": a 3 413 625-point arb (6.51 MB) answers ARWV? at
        # 10 s and not at 6, with the selection having taken. Loading millions of points into the
        # playback buffer is real work, and a raise over a correct selection is the same false-alarm
        # class as a spurious wedge report.
        #
        # LIKELY MECHANISM, the owner's reading and it fits: selecting an arb copies it out of internal
        # FLASH into the fast RAM that feeds the FPGA driving the DAC. That predicts the delay scales with
        # the POINT COUNT rather than with anything else, which is what the observations show -- a
        # 1942-point arb answers instantly, a 3 413 625-point one needs more than 6 s. Inference, not a
        # measurement: nothing here proves the copy exists, only that selection cost grows with size.
        got = self.query(f'C{ch}:ARWV?', timeout=120) or ''
        want = name[:-4] if name.endswith('.bin') else name
        # NO FOLDER HANDLING HERE, DELIBERATELY: a waveform in a subdirectory CANNOT BE SELECTED AT ALL.
        # Measured -- 34 vectors written as 'SERIAL\name' are listed by STL? USER, and ARWV NAME then
        # refuses every form of the request, by path ('SERIAL\name', 'SERIAL/name') and by basename
        # alike, leaving the previous selection playing. The store is effectively flat, so a name with
        # a separator in it is a name that will never work.
        #
        # This check is what found that. The first probe looked like a success because WVDT leaves its own
        # write selected, so reading ARWV? straight after an upload reports the upload rather than the
        # select -- park the selection on a known ROOT vector first, or the test proves nothing.
        if want.lower() not in got.lower():
            raise RuntimeError(
                'C%d:ARWV NAME,%s did not take -- the generator still reports %r. The waveform is '
                'probably not on the instrument; upload it (bench_matrix.py --upload) rather than '
                'trusting a silent select, which leaves the PREVIOUS waveform playing.'
                % (ch, name, got.strip()))
        self.write(f'C{ch}:BSWV AMP,{amp_vpp},OFST,{offset_v}')
        self.truearb(srate_sa_s, ch=ch)
        self.assert_truearb(ch=ch)

    def upload_arb(self, name, codewords, amp_vpp, srate_sa_s, offset_v=0.0,
                   ch=1):
        """Push a waveform over the LAN instead of via the USB key.

        Guide section 3.32. LENGTH is omitted deliberately: the parameter table
        says it "is not necessary for the X series", and the SDG2000X is one.

        Useful for a sweep whose waveform changes per step, where writing files
        to the key first would mean a physical visit. codewords is a sequence of
        ints in -32768..32767.
        """
        n = len(codewords)
        # TWO POINTS MINIMUM, per the manual's 4-byte floor -- this said 1, which is out of spec and would
        # have produced a 2-byte waveform. write_raw refuses it anyway; this makes the two agree.
        if not (SDG_MIN_WAVE_BYTES // 2 <= n <= SDG_MAX_PTS):
            raise ValueError(f'{n} points outside {SDG_MIN_WAVE_BYTES // 2}..{SDG_MAX_PTS}')
        for c in codewords:
            if not (-32768 <= c <= 32767):
                raise ValueError(f'codeword {c} outside -32768..32767')
        self._check_vpp(amp_vpp)
        payload = struct.pack('<%dh' % n, *codewords)
        self.write_raw(f'C{ch}:WVDT WVNM,{name},WAVEDATA,', payload)
        self.write(f'C{ch}:ARWV NAME,{name}')
        self.write(f'C{ch}:BSWV AMP,{amp_vpp},OFST,{offset_v}')
        self.truearb(srate_sa_s, ch=ch)       # last, then verified -- see load_arb_file
        self.assert_truearb(ch=ch)

    # ---------------- channel combining ----------------
    def combine(self, on=True, ch=1):
        """Primitive: set one channel's merge switch. Prefer combine_pair().

        Guide section 3.42, available on the SDG2000X.
        """
        self.write(f'C{ch}:CMBN {"ON" if on else "OFF"}')

    def combine_pair(self, sum_ch=1):
        """Sum onto ONE connector and leave the other carrying its own channel.

        This is what lets the clean logic waveform live on CH1 at a tight
        amplitude while the impairment comes from CH2 as a live, sweepable
        parameter -- so finding the level at which the decoder breaks needs no
        new files, just a different AMP on CH2.

        WHY THE PARTNER IS SET EXPLICITLY OFF RATHER THAN LEFT ALONE. The user
        manual's Wave Combine section is symmetric and per-port: "the output port
        of channel 1 [...] can output the waveform of CH1 in normal mode and
        CH1+CH2 in merge mode; Similarly, the output port of channel 2 [...] CH2
        in normal mode and CH1+CH2 in merge mode." So if BOTH switches are on,
        BOTH connectors emit the sum -- and the diagnostic cable from CH2 to
        scope CH2 then shows the sum a second time instead of the impairment
        alone.

        That failure is quiet and expensive: subtracting the sum from the sum
        yields zero, which reads as "no impairment present" rather than
        "misconfigured", and it would silently make the combine-linearity check
        impossible while appearing to pass it. Hence both switches are always
        written, never assumed.

        STILL UNVERIFIED: whether the summed output saturates below the sum of
        the two amplitudes. Neither the programming guide nor the user manual
        says. Measure it with the scope -- fix CH1, step CH2, confirm the sum is
        linear -- before trusting the axis of any swept result.
        """
        other = 2 if sum_ch == 1 else 1
        self.combine(True, ch=sum_ch)
        self.combine(False, ch=other)

    def sync(self, on=True, ch=1):
        """The Aux BNC marker pulse at the start of each waveform cycle.

        Guide section 3.10. Worth a scope channel: it pins the arb's first
        sample in absolute time, so a byte-level disagreement between the DMM
        and the scope localises to a specific BIT rather than merely being
        counted. Use the scope's deep-memory pair (CH1 and CH3) so this costs no
        capture depth on the signal channel.
        """
        self.write(f'C{ch}:SYNC {"ON" if on else "OFF"}')

    # ---------------- impairments, on CH2, all built-in ----------------
    # Each of these maps onto a knob the offline generator already has, so each
    # has an offline-measured breakdown point to compare the hardware against.
    # That is the difference between "the noisy vector decoded" and a curve.

    def impair_off(self, ch=2):
        self.write(f'C{ch}:OUTP OFF')

    def impair_drift(self, vpp, freq_hz=37.0, ch=2):
        """Slow baseline wander. The offline counterpart is GEN_DRIFT.

        Frequency must be well below the byte rate so a whole capture sees a
        monotonic-looking shift rather than an oscillation -- that is what makes
        it eat the hysteresis budget, since the threshold is decided ONCE for
        the whole capture. Offline the knee is at 0.7 V peak on a 3.3 V swing:
        every byte survives 0.6 V, bytes start to be lost at 0.7 V, and the
        "baseline unstable" warning appears exactly where loss begins. vpp here
        is peak-to-peak, so 0.6 V peak is vpp = 1.2.

        37 Hz, NOT 50 or 60. The coax shield commons the SDG, the scope and the
        DMM's INPUT LO while the first two are already commoned through mains
        earth, so the resulting loop's dominant pickup is at the line frequency
        -- and a digitizing capture has NO line rejection at all, because 1 us
        aperture samples do not average over a line cycle the way an NPLC
        reading does. Injecting the drift at 50 Hz would put the impairment
        exactly on top of the artefact it can be confused with, and a swept
        result would then be unattributable. Any frequency clear of 50, 60 and
        their low harmonics works; this one is.
        """
        self._check_vpp(vpp)
        self.write(f'C{ch}:BSWV WVTP,SINE,FRQ,{freq_hz},AMP,{vpp},OFST,0')

    def impair_spikes(self, vpp, rate_hz=1000.0, width_s=2e-6, ch=2):
        """Impulse noise. The offline counterpart is GEN_SPIKES.

        A narrow PULSE rather than an arb, so amplitude, rate and width are all
        live parameters. Note the offline case stacks overlapping spikes and
        this does not, so the hardware worst case is the single-spike
        amplitude -- a difference worth remembering when the two are compared.
        """
        self._check_vpp(vpp)
        self.write(f'C{ch}:BSWV WVTP,PULSE,FRQ,{rate_hz},AMP,{vpp},OFST,0,'
                   f'WIDTH,{width_s},RISE,{max(width_s / 10.0, 1e-8)}')

    def impair_noise(self, stdev_v, bandwidth_hz=None, ch=2):
        """Broadband noise. The offline counterpart is GEN()'s noise option.

        AMP is not valid for WVTP,NOISE -- the level is STDEV in volts RMS
        (guide's BSWV parameter table), which is a different quantity from the
        peak amplitudes everywhere else here.

        BAND-LIMIT IT. Unbandlimited noise from a 1.2 GSa/s generator puts most
        of its energy far above the DMM's 440 kHz digitize bandwidth, where the
        front end removes it before the decoder ever sees it. A sweep without
        band-limiting would appear to show the decoder tolerating far more noise
        than it really does, and the error is entirely invisible on the panel.
        Default here is the digitize bandwidth itself.
        """
        if bandwidth_hz is None:
            bandwidth_hz = 440e3
        self.write(f'C{ch}:BSWV WVTP,NOISE,STDEV,{stdev_v},MEAN,0')
        self.write(f'C{ch}:BSWV BANDSTATE,ON')
        self.write(f'C{ch}:BSWV BANDWIDTH,{bandwidth_hz}')

    # ---------------- helpers ----------------
    def _check_vpp(self, vpp):
        if not (0 < vpp <= SDG_MAX_VPP):
            raise ValueError(f'{vpp} Vpp outside the 0..{SDG_MAX_VPP} Vpp '
                             f'ceiling -- this generator cannot produce it')

    def close(self):
        """Shut the session down cleanly, not just locally.

        A bare close() drops the local file descriptor; shutdown() sends FIN so the
        generator is told the session ended. That matters because this instrument
        appears to accept only one LAN client: after a run that died mid-command,
        subsequent connections were ACCEPTED and then answered nothing at all,
        which looks exactly like a firmware hang and is indistinguishable from one
        without trying this first. Best-effort and ordered, because shutdown() on
        an already-broken socket raises and must not mask the close.
        """
        if self.s is not None:
            try:
                self.s.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                self.s.close()
            except Exception:
                pass
            self.s = None


if __name__ == '__main__':
    import sys
    if '--dry' in sys.argv:
        # Print the command stream a full Phase 4 step would produce, so the
        # orchestration can be read and checked with the bench powered down.
        g = SDG(transport='dry')
        g.combine_pair(sum_ch=1)
        g.sync(True, ch=1)
        g.load_arb_file('v41.bin', amp_vpp=10.0, srate_sa_s=100000)
        g.impair_drift(vpp=1.2)
        g.output(True, ch=1)
        g.output(True, ch=2)
        for c in g.log:
            print(c)
    else:
        g = SDG()
        print('IDN :', g.idn())
        print('CH1 :', g.state(1))
        g.close()
