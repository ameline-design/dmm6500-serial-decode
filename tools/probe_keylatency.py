#!/usr/bin/env python3
"""How long after a key is physically inserted does the instrument admit it exists?

ANSWERED, so this does not need re-running to settle the question it was written
for. file.usbdriveexists() is a COARSE signal and the app already polls it far
faster than it changes:

    removal, as seen on the panel      prompt, every time, including on a
                                       sub-second out-and-in
    insertion, as seen on the panel    about 2 s before the buttons return, with
                                       or without a button press in between
    key out, then back after ~10 s     both transitions reported to a host poll

So the two seconds an operator sees after pushing a key in is the firmware
enumerating and mounting it. THE PANEL CANNOT BEAT THAT, by press or by tick:
sdec.ui_keypoll() asks the same usbdriveexists() a press or a tick asks, and while
it answers 0 every caller gets 0. The argument that settles it is the DIRECTION
ASYMMETRY -- removal prompt, insertion slow, through identical code -- which no
app logic can produce.

A CAUTION ON THIS TOOL'S OWN EVIDENCE. One run of it saw a single transition in
40 s while the operator reported several complete pull-and-replace cycles, and
the panel showed the buttons going away on each one -- so usbdriveexists() did
return 0 each time and the poll simply was not running when they happened. This
probe is launched in the background and the operator acts on their own clock, so
THE WINDOWS ARE NOT SYNCHRONISED unless someone makes them be. Do not read a
missing transition as the firmware failing to notice; read it as a window
mismatch until the two are tied together.

Nothing else reports it sooner. Measured with a key seated but the port lost:
usbdriveexists 0, fs.is_dir('/usb1') false, fs.readdir nil, file.open('/usb1')
2204 Directory not found. And file.open is unusable as a poll anyway -- it posts
an event when the path is absent, where fs.is_* and usbdriveexists are silent.

TWO WAYS TO MEASURE THIS WRONG, both of which cost something here:

  * AN IN-INSTRUMENT POLLING LOOP DOES NOT WORK AND CAN KILL THE PORT. A Lua
    `while` polling usbdriveexists() never yields, so the firmware never
    re-evaluates the slot: 60 s of it, with the key pulled and re-inserted
    several times, reported transitions=0 with the value frozen at its starting
    1. That run also left the USB port dead -- a seated key invisible to every
    call above -- and only a power cycle brought it back.
  * UNTHROTTLED HOST POLLING MAKES THE PANEL SLUGGISH. Without POLL_HZ this
    reaches 768 Hz, i.e. 768 commands a second at the instrument, and the front
    panel goes visibly slow to respond because event dispatch competes with the
    socket. Confirmed by the operator, and confirmed recovered when it stopped.

So: poll from the HOST, one q() per sample, throttled. 30 Hz is 33 ms of
resolution against a delay measured in seconds.

    python3 tools/probe_keylatency.py --seconds 40

Then pull the key and push it back in. LEAVE IT OUT FOR SEVERAL SECONDS -- a fast
flick is below the firmware's resolution and will record nothing.
"""
import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402

# NO IN-INSTRUMENT POLLING LOOP. The obvious implementation -- a Lua `while` polling
# file.usbdriveexists() -- DOES NOT WORK and is actively harmful. Measured: 60 s of a tight
# loop while the key was pulled and re-inserted several times reported transitions=0, the
# value frozen at its starting 1, because a Lua loop never yields and the firmware
# re-evaluates the slot only between commands. Worse, that run left the USB port dead --
# usbdriveexists 0, fs.is_dir('/usb1') false, file.open('/usb1') 2204 Directory not found,
# with a key physically seated -- and only a power cycle brought it back.
#
# SO THE POLL IS HOST-SIDE, one q() per sample. Each is a separate command, so the
# interpreter yields between them.
#
# AND IT IS THROTTLED, which is not optional. Unthrottled this reaches 768 Hz -- 768
# commands a second at the instrument -- and the front panel goes visibly sluggish because
# the event dispatch is competing with the socket. 30 Hz gives 33 ms of resolution against
# a delay measured in seconds, and leaves the panel alone. Do not remove POLL_HZ to get a
# finer number: the number is not the bottleneck, and the last tool that hammered this port
# cost a power cycle.
POLL_HZ = 30.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seconds', type=float, default=40.0,
                    help='how long to watch the slot')
    a = ap.parse_args()

    d = DMM()
    try:
        print(d.q('print(localnode.model, localnode.version)'))
        # NO CUES FROM HERE. Anything this prints goes to the operator's log, not to their
        # eyes in real time, so a cue they cannot see is worse than none. The protocol that
        # needs no clock on their side: pull the key and push it STRAIGHT back in, as fast as
        # the hand allows. The out-time is then under a second and known, so the gap between
        # the 1->0 report and the 0->1 report is that second plus the asymmetry between
        # removal and insertion -- which is the mount time, and the only number that matters.
        print('\n  PULL THE KEY AND PUSH IT STRAIGHT BACK IN, as fast as you can.')
        print('  Repeat three or four times over the next %.0f s.\n' % a.seconds)
        t0 = time.time()
        last = d.q('print(file.usbdriveexists())')
        print('  %7.2f s  start state %s' % (0.0, last))
        marks, nsamp = [], 0
        period = 1.0 / POLL_HZ
        while time.time() - t0 < a.seconds:
            now = time.time() - t0
            v = d.q('print(file.usbdriveexists())')
            nsamp += 1
            if v != last:
                t = time.time() - t0
                marks.append((t, last, v))
                print('  %7.2f s  usbdriveexists %s -> %s' % (t, last, v))
                last = v
            slack = period - (time.time() - t0 - now)
            if slack > 0:
                time.sleep(slack)
        print('\n  %d samples in %.0f s (%.0f Hz)' % (nsamp, a.seconds, nsamp / a.seconds))
        gaps = []
        for i in range(len(marks) - 1):
            if marks[i][2] == '0' and marks[i + 1][2] == '1':
                gaps.append(marks[i + 1][0] - marks[i][0])
        print('\n  == gap from "key gone" to "key back", per flick ==')
        for i, g in enumerate(gaps):
            print('    flick %d: %.2f s' % (i + 1, g))
        if gaps:
            m = sum(gaps) / len(gaps)
            print('\n    mean %.2f s over %d flick(s).' % (m, len(gaps)))
            print('    Subtract the time the key was actually out (well under a second for a')
            print('    fast flick) and what is left is the firmware mount time -- the floor no')
            print('    press and no tick can beat. The 2 Hz tick adds at most 0.5 s on top.')
        print('  events:', d.q('print(tostring(eventlog.getcount()))'))
    finally:
        d.close()


if __name__ == '__main__':
    main()
