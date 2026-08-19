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
import socket
import struct
import time

try:
    from instruments import SDG_IP, SCPI_PORT, SDG_MAX_VPP, SDG_MAX_PTS, \
        SDG_MIN_SRATE, SDG_MAX_SRATE
except ImportError:      # standalone use, e.g. copied to another machine
    SDG_IP, SCPI_PORT = '10.0.1.79', 5025
    SDG_MAX_VPP, SDG_MAX_PTS = 20.0, 8388608
    SDG_MIN_SRATE, SDG_MAX_SRATE = 1e-6, 75e6

SDG_PORT = SCPI_PORT     # kept: existing callers import this name


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
        MEASURED 2026-08-16: four consecutive WVDT uploads of 170-210 kB WEDGED the
        generator's remote interface completely -- it went on playing the loaded
        waveform correctly and forever, while accepting TCP connections on both
        5024 and 5025 and answering nothing on either, including *IDN?. Only a power
        cycle brought it back, and it has no smart plug, so it costs a human.

        The generator is evidently still digesting the upload when the next command
        arrives. A flat 0.1 s is plenty for a 40-byte BSWV and nowhere near enough
        for 200 kB, so the wait scales: ~1 s per 100 kB on top of the base settle.
        Cheap insurance against the one failure mode on this bench that cannot be
        recovered from in software.
        """
        self.log.append(f'{prefix}<{len(payload)} binary bytes>')
        if self.dry:
            return
        self.s.sendall(prefix.encode() + payload + b'\n')
        time.sleep(self.settle + len(payload) / 100000.0)

    def query(self, cmd, timeout=6):
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
        Measured 2026-08-16: after a 178 kB WVDT upload the generator stops
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

        WHY THIS EXISTS: repeated 170-210 kB WVDT uploads wedge this generator's
        LAN service (see write_raw). A sweep that re-uploads the same five vectors
        on every run does hundreds of kilobytes of writes for no new information --
        the waveforms are stored on the instrument and only need selecting. Once
        each vector is up, this is the cheap path and it does not touch the failure
        mode at all.

        Same ordering discipline as load_arb_file: TrueArb last, then verified.
        """
        self._check_vpp(amp_vpp)
        self.write(f'C{ch}:ARWV NAME,{name}')
        # READ THE NAME BACK. Selecting a waveform that is not on the instrument does not fail --
        # the previous one keeps playing, so every later measurement is attributed to the wrong
        # stimulus. Measured 2026-08-19: twelve vectors added to a suite but never uploaded, and all
        # twelve "failed" against the PREVIOUS vector's bytes. TrueArb was verified below; the name,
        # which is the point of the call, was not.
        # A GENEROUS READBACK TIMEOUT, because selecting a LARGE waveform is slow and the default 6 s
        # turns that into a false "did not take". Measured 2026-08-19: a 3 413 625-point arb (6.51 MB)
        # answered ARWV? at 10 s and not at 6, and the selection HAD taken -- so the raise below fired
        # over a correct selection, which is the same false-alarm class as the wedge report in
        # bench_sync.sdg_alive(). Loading millions of points into the playback buffer is real work.
        #
        # LIKELY MECHANISM, the owner's reading and it fits: selecting an arb copies it out of internal
        # FLASH into the fast RAM that feeds the FPGA driving the DAC. That predicts the delay scales with
        # the POINT COUNT rather than with anything else, which is what the two observations show -- a
        # 1942-point arb answers instantly, a 3 413 625-point one needs more than 6 s. Inference, not a
        # measurement: nothing here proves the copy exists, only that selection cost grows with size.
        got = self.query(f'C{ch}:ARWV?', timeout=30) or ''
        want = name[:-4] if name.endswith('.bin') else name
        # NO FOLDER HANDLING HERE, DELIBERATELY: a waveform in a subdirectory CANNOT BE SELECTED AT ALL.
        # Measured 2026-08-19 -- 34 vectors written as 'SERIAL\name' were listed by STL? USER and then
        # ARWV NAME refused every form of the request, by path ('SERIAL\name', 'SERIAL/name') and by
        # basename alike, leaving the previous selection playing. So the store is effectively flat and a
        # name with a separator in it is a name that will never work.
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
        if not (1 <= n <= SDG_MAX_PTS):
            raise ValueError(f'{n} points outside 1..{SDG_MAX_PTS}')
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
