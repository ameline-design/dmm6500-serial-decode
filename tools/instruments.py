#!/usr/bin/env python3
"""One place for the bench's addresses and the facts about it that code needs.

Every other tool imported its own hardcoded IP -- dmmrun.py, siglent.py and
screenshot.py each had a different constant for the same three boxes -- which is
fine until the scope becomes a fourth and one of them is missed. Addresses are
static DHCP reservations on the router, so they are stable, but they belong in
one file and be overridable from the environment for the day one of them is not.

The bench:

    +--------------+                    +------------------+
    | SDG2122X     | CH1 out --+--coax--| DMM6500 INPUT HI |   the decoder
    | 16-bit AWG   |           |        +------------------+
    | CH2 combined |           |        +------------------+
    | into CH1     |           +--coax--| SDS1204X-E CH1   |   the oracle
    +--------------+   splitter         +------------------+
           ^                                     ^
           +----------------- USB ---------------+   (scope drives the SDG for
                                                      Bode plots -- see the
                                                      hazard note below)

All three on one gigabit switch at 100 Mbit, plus a HomeKit smart plug feeding
the DMM6500 so the once-per-power-cycle UI build limit can be recovered from
without a human present.
"""
import os

# --------------------------------------------------------------------------
# Addresses. Environment overrides so a moved instrument needs no code change.
# --------------------------------------------------------------------------
DMM_IP = os.environ.get('DMM_IP', '10.0.1.151')
SDG_IP = os.environ.get('SDG_IP', '10.0.1.79')
SCOPE_IP = os.environ.get('SCOPE_IP', '10.0.1.163')   # SDS1204X-E, found 2026-08-16

SCPI_PORT = 5025          # raw socket on all three
TELNET_PORT = 5024        # scope only, echoes a prompt; 5025 is the clean one
# ...except 5024 is open on the GENERATOR too, so it does not identify the scope. What does:
# 5025 answers *IDN? on all three, and only one of them says SDS. Found by sweeping the subnet
# for 5025 and asking each hit who it was, which took seconds -- worth doing again rather than
# trusting a remembered address after anything is re-plugged.
#
#   10.0.1.163  Siglent Technologies,SDS1204X-E,SDSMMDBC2R0625,7.3.6.1.37R17
#   10.0.1.79   Siglent Technologies,SDG2122X,SDG2XCAD1R2808,2.01.01.38R4
#
# THE SCOPE IS ON THE 7.x FIRMWARE LINE. docs/SDS1002X-E-Firmware-Revise-History.txt tops out at
# 1.3.28 and its compatibility table covers 1.3.x and 5.1.3.x sources only -- 7.x appears nowhere
# in it. That document is for a different series, and an .ADS taken from it is rejected as
# "invalid" by this scope. Recorded because the failure looks like a bad download or a bad eject
# and is neither.
SCOPE_FW = '7.3.6.1.37R17'

# DMM6500 web UI, for screenshot.py's virtual-front-panel route.
DMM_USER = os.environ.get('DMM_USER', 'admin')
DMM_PASSWORD = os.environ.get('DMM_PASSWORD', 'admin')

# --------------------------------------------------------------------------
# The smart plug. HomeKit, so it is driven through the macOS Shortcuts CLI
# rather than any network protocol -- there is no IP to put here.
# --------------------------------------------------------------------------
PLUG_ON_SHORTCUT = os.environ.get('PLUG_ON_SHORTCUT', 'DMM Power On')
PLUG_OFF_SHORTCUT = os.environ.get('PLUG_OFF_SHORTCUT', 'DMM Power Off')

# Seconds the DMM must stay unpowered for a power cycle to be a power cycle.
# A short interruption can leave the mainboard powered through bulk capacitance
# and the firmware never restarts, which looks exactly like a cycle that did not
# fix anything.
PLUG_MIN_OFF_S = 15.0
# Seconds to allow for the LXI stack after power returns. It answers ICMP well
# before it accepts a socket, so readiness is polled with *IDN? not ping.
PLUG_BOOT_TIMEOUT_S = 90.0

# --------------------------------------------------------------------------
# Hard facts that shape what the drivers may do. These are not preferences.
# --------------------------------------------------------------------------

# CALIBRATION IS OFF LIMITS ON BOTH INSTRUMENTS. ki.cal exists on the DMM6500
# and is never touched: no *CAL, no adjustment command, no write to calibration
# state, on the DMM or the SDG. Reads of dmm.calibration.* are pointless anyway.
# Any driver here that grows a calibration path is a bug.

# The DMM6500 accepts only ONE controlling socket. A second one silently steals
# replies -- reads return '' or raise BrokenPipe, with no error to say why.
# dmmrun.acquire_single_instance() holds an flock; use it.
DMM_SINGLE_CLIENT = True

# One UI build per power cycle. sdec.start() may be called once; every refresh
# after it is settext-only. A second build crashes the firmware hard enough to
# need intervention -- which is what the smart plug is for.
DMM_ONE_BUILD_PER_POWER_CYCLE = True

# NEVER CALL display.waitevent() FROM A REMOTELY LOADED SCRIPT. It wedges the instrument: the TSP
# interpreter stops answering, the control socket goes silent, clear_dead_sockets() and reconnecting
# do not recover it, and only a power cycle does.
#
# Measured 2026-08-17, twice. Called as display.waitevent(0) -- documented as "number of seconds to
# wait for an event, forever if not specified" -- FIRST from a script while the app was running (the
# socket was reset), then from a bare instrument with no custom screen and no app built (no reply at
# all, then four reconnect attempts returned nothing). So a timeout of 0 does NOT mean "poll and
# return immediately"; with no waitevent-enabled object to report, it blocks, and it takes the remote
# interface down with it.
#
# This matters beyond the harness. The instrument's own display documentation shows waitevent(0)
# polled inside a long loop to check for a Stop press, and that pattern is the obvious way to let a
# long-running handler stay cancellable. On this firmware it is a trap: an app that polls it and
# finds nothing pending would hang the panel with no way back but the mains switch.
#
# THE MECHANISM THAT DOES WORK IS BELOW -- a trigger blender latching the TRIGGER key.
DMM_WAITEVENT_WEDGES_THE_INSTRUMENT = True

# HOW TO CANCEL A RUNNING HANDLER ON THIS INSTRUMENT. The only mechanism found, and the one the app
# uses: the front-panel TRIGGER key generates trigger.EVENT_DISPLAY, an event blender LATCHES it in
# firmware, and blender wait(t) reads the latch without blocking. Measured 2026-08-17 with
# tools/bench_cancelkey.py, on a bare instrument and with the app running:
#
#   * a press latches with NOTHING armed -- no trigger model has to be waiting on the key
#   * THE LATCH IS SET WHILE LUA SPINS: pressed during a deliberate 10 s busy loop, seen by the poll
#     afterwards, twice. This is the fact the one-press design rests on
#   * wait(0.001) returns in 1.1 ms, wait(0.05) in 50.1 ms -- it polls. NEVER PASS ZERO: that is how
#     display.waitevent behaves, and the risk is not worth the microsecond
#   * 1.06 ms per poll amortised over 200; nothing reaches the event log
DMM_TRIGGER_KEY_LATCHES_ON_A_BLENDER = True

# AND TWO THINGS THAT DO NOT WORK, both measured the same day, so nobody re-derives them:
#
# *TRG (trigger.EVENT_COMMAND) CANNOT cancel a running handler. Sent 2 s into a 6 s busy loop it never
# reached the latch: the command queue is drained only when the interpreter is idle. It is useless as a
# harness stand-in for a finger, which is what it was tried for.
DMM_BUS_TRIGGER_CANNOT_INTERRUPT_A_SCRIPT = True
#
# A TRIGGER TIMER *DOES* fire mid-script, because it is firmware: measured firing 2.019 s into a 6 s
# busy loop and latching on the same blender. tools/bench_panel.py wires trigger.EVENT_TIMER1 as a
# temporary extra stimulus so the sweep can test a cancel with no finger on the panel.
DMM_TRIGGER_TIMER_FIRES_DURING_A_SCRIPT = True

# THE FRONT PANEL HAS NO KNOB, and no key other than TRIGGER is visible to a script. The controls are
# Home, Menu, Apps, Help (left), Enter, Exit, Function, Trigger (right), the TERMINALS front/rear
# switch and the power button. The display API's event table lists events for OBJECTS only, plus
# EVENT_ENDAPP on a screen and EVENT_KNOB_ROTATE/EVENT_KNOB_ENTER -- which are "only on instruments
# with a front panel knob", i.e. not this one (that is the 7510/DMM7512 class).
#
# So the pollable physical inputs are exactly two: the TRIGGER key via the blender latch above, and
# `dmm.terminals` (read-only, dmm.TERMINALS_FRONT / _REAR), which reflects the TERMINALS switch.
#
# THE TERMINALS SWITCH IS NOT A SPARE BUTTON, however tempting a second pollable input looks: it
# PHYSICALLY ROUTES the inputs between the front and rear connectors, so using it as a control would
# disconnect the very line being decoded. It is readable state, not an input.
#
# An in-app help viewer therefore needs on-screen paging buttons; there is no key to hang it off.
DMM_NO_FRONT_PANEL_KNOB = True

# SDG2122X output ceiling: 20 Vpp into high-Z, i.e. +/-10 V. BSWV
# MAX_OUTPUT_AMP takes {1-20} and the published specs give max amplitude as
# +/-10 V. A vector needing more than this cannot be produced here at all.
SDG_MAX_VPP = 20.0

# SDG2000X arb: bin length 4 B to 16 MB at 2 bytes per point.
SDG_MAX_PTS = 8388608
# TrueArb sample rate range, Sa/s.
SDG_MIN_SRATE = 1e-6
SDG_MAX_SRATE = 75e6

# The DMM6500 digitizes at 1 MSa/s maximum. The app fixes the 10 V range, whose
# digitize bandwidth is 440 kHz -- against 210 kHz on 1 V and 17 kHz on 100 V --
# so the range choice is a bandwidth choice, not just a headroom one.
DMM_MAX_SRATE = 1e6
DMM_DIGITIZE_BW_HZ = 440e3

# HAZARD: LARGE WVDT UPLOADS WEDGE THE SDG, AND IT HAS NO SMART PLUG.
#
# Measured 2026-08-16. Repeated C1:WVDT uploads of 170-210 kB stop the generator
# responding on BOTH 5025 and 5024 -- connections are accepted, nothing is ever
# answered, including *IDN?. It goes on playing the loaded waveform correctly and
# indefinitely, so the failure is invisible from the signal side. Waiting does not
# clear it (45 s), and it progressed from "touchscreen fine, LAN dead" to the
# front-panel Output button not responding either, so it is a firmware hang and not
# merely a stale session. Recovery is a POWER CYCLE, and unlike the DMM6500 there is
# no plug shortcut -- it costs a human.
#
# So: upload each vector ONCE per power cycle and select it by name afterwards
# (siglent.select_arb, tools/bench_uart.py --reuse). write_raw() also now settles in
# proportion to the payload, and close() shuts the socket down rather than dropping
# it. None of that is known to be sufficient; not re-uploading is what avoids it.
SDG_UPLOAD_WEDGE_HAZARD = True
# Generator firmware was updated 2026-08-17: 2.01.01.38R4 -> 2.01.01.39R7. The hazard above was
# measured on 38R4 and has NOT yet been retested on 39R7 -- tools/sdg_hang_repro.py exists for
# exactly that, and until it has been run with --arm this flag stays True. A firmware update is a
# reason to re-measure, not a reason to assume.
SDG_FW = '2.01.01.39R7'
SDG_UPLOAD_SAFE_BYTES = 65536      # below this, uploads have never wedged it

# RE-MEASURED ON 39R7, 2026-08-19, AND THE CEILING BOUNDS A COUNT AS MUCH AS A SIZE.
#
# One session, in this order:
#   34 uploads of 3.8-63 kB, ~900 kB in total   -> fine, all 34 verified in STL? USER
#   1st over-ceiling upload, 213 750 B          -> fine: wrote in 2.3 s, selected, DECODED on the DMM
#   2nd over-ceiling upload, 107 250 B          -> fine; the "wedge" first reported here was a FALSE
#                                                  ALARM, see the session-limit note below
#   3rd over-ceiling upload, 213 750 B          -> WEDGED. The write itself completed and the waveform
#                                                  was present after the power cycle; the SCPI service
#                                                  died immediately after it.
#
# So small writes do not accumulate risk -- 900 kB of them changed nothing -- while large ones do, and
# THREE was enough. That is the same order as the original record of four consecutive 170-210 kB on 38R4,
# so 39R7 is no more tolerant. The constant therefore stays 65536, but the operational rule is: fewer
# than three over-ceiling writes between power cycles, and prefer the USB key for a batch.
#
# AND SIZE IS NOT THE VARIABLE AT ALL. After the power cycle, ONE upload of 1 707 250 B -- 1.63 MB, 26x
# the ceiling and 8x the largest that had ever been sent -- completed in 17.3 s, left the SCPI service
# answering on the open session, appeared in STL? USER, selected, and PLAYED CORRECTLY: the DMM decoded
# it at 9600 8N1 and 120 of its bytes were a contiguous run of the 8192-byte payload oracle (offset 8097,
# wrapping the loop). A 1.63 MB single upload is therefore safer than a third 213 kB one.
#
# CONFIRMED AGAIN with a SECOND large upload after that power cycle: 6 827 250 B (6.51 MB, 104x the
# ceiling, 3 413 625 points -- 41% of SDG_MAX_PTS) wrote in 69 s, stayed alive, selected, and played
# correctly (the DMM decoded it at 9600 8N1 and 120 bytes were a contiguous run of the 32768-byte oracle
# at offset 1676). So TWO large uploads totalling 8.14 MB did not wedge it, while THREE totalling 533 kB
# did. Bytes are not the variable; the number of large writes is.
#
# THE HARDWARE THIS ALL FOLLOWS FROM, per the owner:
#
#   CPU board     ARM A8 + ONE 128 Meg DDR3 chip + ONE 128 Meg flash chip
#      |
#      |          a SERIAL LINK
#      v
#   analog board  FPGA with TWO 128 Meg DDR3 chips attached, driving the DAC
#
# "128 Meg" IS BYTES HERE, AND THE FREE-SPACE FIGURE IS WHAT PINS IT. DRAM and flash parts are specified
# in bits or in address depth, so 128 Meg could have meant 16 MB (128 Mbit) -- and I had already been
# wrong by a factor of a thousand once in this same paragraph. The front panel reports ~80 MB free on
# internal flash, which a 16 MB chip cannot do. So the flash is 128 MB, and the DDR3 parts are read the
# same way: 128 MB on the CPU board, 2 x 128 MB = 256 MB on the FPGA.
#
# THE TWO CHIPS ARE A WIDER BUS, NOT A BANK PER CHANNEL, and bandwidth is what settles it. The owner
# reports the FPGA and its DDR fast enough to stream BOTH 16-bit channels at the DAC's full rate: that is
# 2 x 1.2 GSa/s x 2 B = 4.8 GB/s. A single x16 DDR3 chip does not reach that below DDR3-2400 (3.2 GB/s at
# DDR3-1600), while two in parallel clear it from DDR3-1333 up -- 75% bus efficiency at DDR3-1600, and arb
# playback is a purely SEQUENTIAL read, which is the best case DRAM has. So the pair has to be ganged.
#
# THE DAC IS DUAL-CHANNEL, 1.2 GSa/s, 16 BITS. Three consequences, and all three RULE THE GENERATOR OUT
# as an explanation for a decode artefact, which is why they are worth writing down:
#
#   * 16 bits is why a .bin is what it is. The file is raw DAC codewords, -32768..32767 little-endian --
#     native to the converter, not a format the firmware translates.
#
#   * THE EDGES THE DMM SEES ARE THE ONES WE RENDER. 1.2 GSa/s against SDG_MAX_SRATE of 75 MS/s is 16x
#     oversampling, so a TrueArb point is held for at least 16 DAC clocks -- and at the 100 kS/s these
#     vectors use, 12 000 of them. DAC transition granularity is 0.833 ns against a rendered edge of
#     15 us (rise = 1.5 samples), so our edge shaping dominates by ~18 000x. Any edge effect in a capture
#     is the vector's or the analog path's, never the converter's.
#
#   * THE SIGNAL PATH AND THE CONTROL PLANE ARE SEPARATE VERDICTS, and it matters that they not be
#     collapsed. Web teardowns and the chip datasheets say this generator does what it claims without
#     glitching, and everything computed here agrees: 16x oversampling at the DAC, three orders of
#     magnitude of spare resolution at a logic threshold, four orders of spare bandwidth. So THE ANALOG
#     SIDE IS TRUSTWORTHY -- when a capture looks wrong, the decoder or the coax is the place to look.
#     That is not a licence to trust the REMOTE INTERFACE, which is demonstrably defective on this
#     firmware and on the previous one: three over-ceiling WVDT writes stop the SCPI service dead. Good
#     hardware with a buggy control plane is an ordinary combination, and dropping the wedge guard
#     because the teardown was reassuring would cost a walk to the bench.
#
#   * AND THERE IS FOUR ORDERS OF MAGNITUDE OF HEADROOM. This project drives ONE channel at 100 kS/s,
#     200 kB/s, which is 1 part in 24 000 of that 4.8 GB/s. Playback starvation is therefore not a
#     candidate mechanism for anything seen in a capture -- the second appealing explanation for the
#     periodic-payload failures to be ruled out by a hardware fact rather than by an experiment.
#
#   * RESOLUTION IS NOT A FACTOR EITHER. Full scale 20 Vpp over 65536 codes is 305 uV per LSB; the 3.3 V
#     logic swing these vectors use spans 10 813 codes, about 13.4 effective bits, and a threshold
#     decision at ~1.63 V sits ~5400 codes from either rail. make_vectors.lua's note that "low
#     utilisation is not an error" is right: a third of full scale still leaves three orders of magnitude
#     more resolution than a logic threshold can use.
#
# WHAT THAT SETTLES:
#
#   * A WAVEFORM IS RESIDENT, NOT STREAMED. SDG_MAX_PTS is 8 388 608 points = 16 MB, which is 12% of ONE
#     128 MB chip. So there is no ping-pong refill during playback and therefore no buffer-swap boundary
#     -- which kills, before it was built on, a tempting candidate mechanism for the periodic-payload
#     failures: that errors might cluster at a fixed payload spacing as banks swapped. There is no swap.
#     (That idea came from misreading the banks as 128 KB, where a 6.8 MB arb could not have been
#     resident and the swap interval would have been a constant ~629 payload bytes at every baud rate.
#     It was arithmetically pretty and the premise was wrong by a factor of a thousand.)
#
#   * SELECTION COST IS THE FLASH -> DDR COPY over that serial link, and it is the generator's one weak
#     link. TIMED CLEANLY: 3884 B selects in 0.51 s, 6 827 250 B in 22.43 s -- a fit of 0.5 s fixed plus
#     311 kB/s marginal, about 2.5 Mbit/s. The largest arb the instrument accepts, 16 MB, is therefore
#     ~54 s. (An earlier figure here said 0.65-1.08 MB/s; it was bracketed from when a query happened to
#     be answered rather than from the copy finishing, and it made select_arb's readback timeout too
#     short for the very case it claimed to cover. 120 s now.)
#
#   * CHANGING THE SAMPLE RATE IS FREE, which is the useful corollary: srate is a few FPGA register
#     writes, measured at 0.01 s of actual work against 22 s to change waveform. So a rate sweep should
#     SELECT ONCE AND VARY srate, never re-select per point. That is exactly what the vector naming
#     already assumes -- no baud rate in a name, because one waveform serves every rate -- so the naming
#     decision and the cheap path coincide.
#
#   * AND QUERIES STALL WHILE A COPY IS IN FLIGHT. This is the mechanism behind every timing anomaly seen
#     today. The SCPI service does not answer during the transfer: C1:SRATE? took 21.72 s immediately
#     after a 6.51 MB select and then 0.00 s twice running. So a query that seems to hang after a large
#     select is waiting, not broken -- and a check that reads "no answer within N seconds" as a wedge will
#     cry wolf. It did, three times.
#
#   * THE CONCLUSION IS INSENSITIVE TO THE READING ANYWAY, which is the useful part: at the SMALLEST
#     interpretation (16 MB a chip) the largest possible arb is still only half of one, so a waveform is
#     resident under every reading. Capacity is not a constraint for this project; the wedge COUNT is.

# The ceiling is consequently a bound on HOW MANY large writes have happened since the last power cycle,
# not on how big any one of them is. It stays at 65536 as the trigger for "count this one", because
# nothing here establishes where between 1 and 3 the real limit sits, and the cost of finding out is a
# human walking to the bench.
#
# THE SDG SERVES ONE SCPI SESSION AT A TIME, and that is indistinguishable from a wedge if you probe with
# a second socket: with a connection already open, a second one is accepted and answers nothing, which is
# exactly the wedge symptom. It produced a false "the LAN service has wedged" over a healthy instrument
# whose very next query on the open socket succeeded. bench_sync.sdg_alive() takes sdg= for this reason.
# The genuine wedge above was confirmed on the LIVE session and again on a fresh socket after closing it.

# AND ON 39R7 THE LAN DIES WITH NO UPLOAD AT ALL -- SO SIZE IS NOT THE ONLY VARIABLE.
#
# Measured 2026-08-17, twice, same shape both times:
#   1. sdg_hang_repro.py --check  ->  BOTH ports answer, 5025 gives the full *IDN?
#   2. bench_uart.py, seconds later  ->  ConnectionRefusedError on the FIRST socket,
#      before a single byte of waveform was sent
# and the second time the FRONT PANEL was wedged too, needing a power cycle.
#
# Note the difference from the 38R4 hazard above: that one ACCEPTED connections and answered
# nothing. This REFUSES them -- a closed port, i.e. the listener is gone, not a busy firmware
# thread. Different symptom, different cause, and zero bytes uploaded either time.
#
# FIRST SUSPECT WAS socket.shutdown(SHUT_RDWR) -- called by siglent.close() and by
# sdg_hang_repro.alive(), and added THIS session as a mitigation for the 38R4 upload wedge, so a
# mitigation causing a worse failure was the obvious story. TESTED AND REFUTED, 2026-08-17: three
# plain-close *IDN? connections, then one closing with shutdown(), then three more -- all seven
# answered. shutdown() does not take the listener down.
#
# REMAINING SUSPECT: PORT 5024. Both refusals came right after sdg_hang_repro.py --check, which
# probes 5024 as well as 5025. 5024 is the telnet-style port that echoes a '>>' prompt, and this
# is a single-session instrument -- an abandoned telnet session is a plausible way to lose the
# listener, and it would explain why a --check poisons the next connect while ordinary 5025
# traffic does not. NOT YET TESTED, because confirming it wedges the generator and costs a human
# a power cycle. Test it deliberately, with someone there, not in passing.
#
# MEANWHILE: --check on 5024 is not worth its risk. Probe 5025 only.
#
# Do NOT size vectors around SDG_UPLOAD_SAFE_BYTES on the assumption that it is the relevant
# variable -- on this firmware it demonstrably is not the only one. Better: upload ONCE and sweep
# the arb SRATE instead (baud = SRATE / samples_per_bit), which needs no re-upload at all.
SDG_SHUTDOWN_SUSPECTED_HAZARD = True

# HAZARD: the scope also drives the SDG over USB for its Bode-plot function. If
# the scope is left in Bode mode it will reprogram the generator underneath any
# run happening here, and the symptom is a stimulus that silently stops matching
# the manifest. Take the scope out of Bode mode before an unattended session.
SCOPE_BODE_HAZARD = True

# Capture depth AND SAMPLE RATE, which trade together and PER PAIR.
#
# The 4-channel scope is two independent channel pairs, (1,2) and (3,4), each with
# its own ADC and acquisition memory. Within a pair:
#     one of the two enabled  -> 1 GSa/s and 14 Mpts
#     both enabled            -> 500 MSa/s and 7 Mpts, each
# The pairs do not affect each other. This is also what the user manual's table
# means by "Single Channel Mode" and "Dual Channel Mode" -- those columns describe
# the state of a PAIR, not the total number of channels enabled, which is why the
# table appears to omit the three- and four-channel cases.
#
# So the wiring here is optimal rather than a compromise: CH1 carries the signal
# with CH2 left DISABLED, giving the signal channel the full 1 GSa/s and 14 Mpts
# no matter what pair (3,4) is doing; and the two markers sit together in pair
# (3,4) at 500 MSa/s and 7 Mpts each, which is ample for a signal whose entire job
# is to produce one edge.
#
# Enabling CH2 to diagnose therefore costs BOTH rate and depth on the signal
# channel -- 500 MSa/s and 7 Mpts -- and does so silently. Still ample (the
# binding vector, v46, is 254 ms and needs only ~1 MSa/s to corroborate 9600 baud,
# i.e. 254 kpts) but it is a real cost, so CH2 is diagnose-only.
#
# Plan windows with the manual's relation, and read the achieved depth off the
# screen ("Curr", upper-right) rather than predicting it:
#     memory depth = sample rate (Sa/s) x waveform length (s/div x div)
SCOPE_MSIZ_INTERLEAVED = ('14K', '140K', '1.4M', '14M')   # MSIZ, one per pair
SCOPE_MSIZ_NONINTERLEAVED = ('7K', '70K', '700K', '7M')   # MSIZ, both per pair
SCOPE_DEEP_CHANNELS = (1, 3)     # one from each pair: full rate and depth on both
SCOPE_CH_SIGNAL = 1      # the summed stimulus, from the T
SCOPE_CH_IMPAIR = 2      # SDG CH2 alone. ENABLE ONLY WHEN DIAGNOSING -- halves CH1
# THE SDG's ARB SYNC IS ABANDONED, DECIDED 2026-08-19. Do not investigate it again.
#
# The reason is arithmetic, not a measurement: SDG2000X_UserManual 12.7 documents the sync as a
# 50 ns pulse, and the DMM6500's EXT TRIG IN specs a MINIMUM PULSE WIDTH of 1 us
# (docs/DMM6500_Specs_April_2018.txt:761). 20x too narrow. It could never have driven this meter
# whether or not the BNC works, so whether it works does not matter to this project.
#
# The Aux In/Out BNC will only ever be used as an INPUT, as the burst trigger for the
# flow-control loop (notes/PROPOSAL-flowcontrol-loop.md). Never as a sync output. That also
# removes a hazard: the BNC is bidirectional, so a sync output left enabled while the DMM drives
# it would tie two push-pull drivers together.
#
# Retracted along the way: an earlier note here asserted the sync "DOES NOT" drive in TrueArb,
# from CH3 reading flat over a 14 ms window. That window had a 1.31 % chance of containing a
# 50 ns pulse at v71's 0.936 Hz, so it was equally consistent with a live pulse being missed.
# The claim was never supportable; it is gone rather than corrected.
#
# CH3 IS THEREFORE FREE -- but that changes nothing for the credit-pulse edge measurement (gate G0
# of the flow-control proposal), and it is worth saying why so nobody rewires for no reason. EITHER
# channel of a pair gets the full 1 GSa/s and 14 Mpts when the other is OFF; only both-enabled
# halves them. So CH4, already wired to the DMM's EXT TRIG OUT, is ALREADY optimal for G0 with CH3
# left off -- CH1 and CH4 are two full-bandwidth channels in different pairs. SCOPE_DEEP_CHANNELS
# below is one valid choice of one-per-pair, not the only one; (1, 4) is equally deep.
# What freeing CH3 actually buys is a SPARE deep channel, for a case that needs to watch a third
# signal at full rate. Nothing today does.
SCOPE_CH_ARBSYNC = 3     # unused; a spare deep channel, no longer allocated to the abandoned sync
SCOPE_CH_DMMWIN = 4      # DMM EXT TRIG OUT: marks the DMM's capture window


# --------------------------------------------------------------------------
# WRITE, THEN READ BACK. The house rule for both Siglent instruments.
# --------------------------------------------------------------------------
# The manuals contain outright errors -- the scope's LIN section documents a baud
# range of "300 to 2000" and then gives an example using 9600, naming the CAN
# command while doing it -- and the firmware on both instruments has been updated
# more recently than the documents describe. So a documented range may be stale in
# either direction: a limit may have been lifted, a parameter renamed, a default
# changed.
#
# Reading the manual harder does not fix that. Reading the INSTRUMENT does. Every
# setter in both SCPI dialects has a matching query, so the robust pattern for any
# setting that would silently corrupt a result is: write it, query it back, and
# compare. One extra round trip, and it is immune to both manual errors and
# firmware drift -- neither of which announces itself.
#
# Use it for settings whose failure is INVISIBLE (a mode that silently falls back,
# a threshold clamped to the vertical scale, a baud rate rejected out of range).
# Do not bother for settings whose failure is obvious on screen.

class VerifyError(RuntimeError):
    pass


def verify(dev, query, expect, what, ci=True):
    """Query `query` on `dev` and require `expect` to appear in the reply.

    dev is any object with .query() and a .dry attribute -- both drivers here
    qualify. Returns the raw reply, or True in dry-run mode where there is no
    instrument to disagree with.
    """
    if getattr(dev, 'dry', False):
        return True
    got = dev.query(query)
    hay, needle = (got.upper(), str(expect).upper()) if ci else (got, str(expect))
    if needle not in hay:
        raise VerifyError(
            f'{what}: asked for {expect!r} but the instrument reports {got!r}. '
            f'The manuals are known to contain errors and the firmware is newer '
            f'than they are, so believe this reply over any documented range.')
    return got


def firmware(dev):
    """*IDN? including the firmware revision.

    Worth recording at the start of every session and into any result file. Both
    instruments have had firmware updates more recent than their manuals, so a
    behaviour that changes between sessions is explicable only if the revision
    that produced each result is known. Without it, a firmware change looks like
    an intermittent fault -- and intermittent faults are the most expensive thing
    to chase on this bench.
    """
    return dev.query('*IDN?')


def have_scope():
    """The scope's address is the one thing on this bench not yet known."""
    return bool(SCOPE_IP)


def describe():
    lines = [
        f'DMM6500     {DMM_IP}:{SCPI_PORT}    the decoder under test',
        f'SDG2122X    {SDG_IP}:{SCPI_PORT}    stimulus, CH1 + CH2 combined',
    ]
    if have_scope():
        lines.append(f'SDS1204X-E  {SCOPE_IP}:{SCPI_PORT}    independent oracle')
    else:
        lines.append('SDS1204X-E  ADDRESS UNKNOWN -- set SCOPE_IP to enable the oracle')
    lines.append(f'plug        shortcuts "{PLUG_ON_SHORTCUT}" / "{PLUG_OFF_SHORTCUT}"')
    return '\n'.join(lines)


if __name__ == '__main__':
    print(describe())
