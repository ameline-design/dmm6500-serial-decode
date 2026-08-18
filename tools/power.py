#!/usr/bin/env python3
"""Power-cycle the DMM6500 through a HomeKit smart plug, and wait for it properly.

WHY: the app may build its UI exactly ONCE per power cycle. A second sdec.start()
crashes the firmware hard enough to need intervention. With a human at the bench
that costs a walk to the front panel; 300 km away it ends the session. This turns
that from a session-ender into a 45-second wait, which is what makes an unattended
run possible at all.

The plug is HomeKit, so there is no IP and no protocol -- it is driven through the
macOS Shortcuts CLI. Create two shortcuts, one per direction, and put their names
in instruments.py (or the environment).

THREE THINGS THIS GETS RIGHT THAT A NAIVE VERSION DOES NOT

1. It confirms the OFF happened. `shortcuts run` succeeds when the shortcut ran,
   not when the plug switched -- HomeKit is fire-and-forget and a failed switch
   returns nothing. If the instrument still answers after the off command, the
   plug did not switch and continuing would run every subsequent test against a
   firmware that was never restarted, producing a whole session of results that
   look fine and mean nothing.

2. It enforces a minimum off time. A brief interruption can leave the mainboard
   running on bulk capacitance; the firmware never restarts and the cycle appears
   to have "not fixed anything".

3. It polls *IDN? on the SCPI port, not ping. The LXI stack answers ICMP long
   before it accepts a socket, so ping-then-connect races and the first command
   of the session is the one that gets lost.
"""
import argparse
import socket
import subprocess
import sys
import time

try:
    from instruments import (DMM_IP, SCPI_PORT, PLUG_ON_SHORTCUT,
                             PLUG_OFF_SHORTCUT, PLUG_MIN_OFF_S,
                             PLUG_BOOT_TIMEOUT_S)
except ImportError:
    DMM_IP, SCPI_PORT = '10.0.1.151', 5025
    PLUG_ON_SHORTCUT, PLUG_OFF_SHORTCUT = 'DMM Power On', 'DMM Power Off'
    PLUG_MIN_OFF_S, PLUG_BOOT_TIMEOUT_S = 15.0, 90.0


class PowerError(RuntimeError):
    pass


def _shortcut(name, dry=False):
    if dry:
        print(f'[dry] shortcuts run "{name}"')
        return True
    try:
        r = subprocess.run(['shortcuts', 'run', name],
                           capture_output=True, timeout=30)
    except FileNotFoundError:
        raise PowerError('the `shortcuts` CLI is not available -- this needs '
                         'macOS with Shortcuts')
    except subprocess.TimeoutExpired:
        raise PowerError(f'shortcuts run "{name}" timed out')
    if r.returncode != 0:
        raise PowerError(f'shortcuts run "{name}" failed: '
                         f'{r.stderr.decode(errors="replace").strip()}')
    return True


def responds(ip=DMM_IP, port=SCPI_PORT, timeout=2.0):
    """Does the instrument accept a socket AND answer *IDN?

    Both halves matter. A socket that connects but never replies is what a
    half-booted LXI stack looks like, and it is indistinguishable from a healthy
    instrument until the first query hangs.
    """
    try:
        s = socket.create_connection((ip, port), timeout=timeout)
    except OSError:
        return False
    try:
        s.settimeout(timeout)
        s.sendall(b'*IDN?\n')
        r = s.recv(256)
        return b'KEITHLEY' in r.upper() or b'MODEL' in r.upper()
    except OSError:
        return False
    finally:
        try:
            s.close()
        except OSError:
            pass


def wait_until(want_up, timeout, ip=DMM_IP, port=SCPI_PORT, poll=2.0,
               dry=False):
    if dry:
        print(f'[dry] wait until {"up" if want_up else "down"} '
              f'(timeout {timeout:.0f} s)')
        return 0.0
    t0 = time.time()
    while time.time() - t0 < timeout:
        if responds(ip, port) == want_up:
            return time.time() - t0
        time.sleep(poll)
    raise PowerError(f'instrument did not come {"up" if want_up else "down"} '
                     f'within {timeout:.0f} s')


def off(ip=DMM_IP, dry=False, confirm_timeout=25.0):
    _shortcut(PLUG_OFF_SHORTCUT, dry=dry)
    # Confirming the OFF is the check a naive harness skips, and it is the one
    # that prevents a whole session of meaningless results.
    return wait_until(False, confirm_timeout, ip=ip, dry=dry)


def on(ip=DMM_IP, dry=False, boot_timeout=None):
    _shortcut(PLUG_ON_SHORTCUT, dry=dry)
    return wait_until(True, boot_timeout or PLUG_BOOT_TIMEOUT_S, ip=ip, dry=dry)


def cycle(ip=DMM_IP, dry=False, min_off=None, tries=3, verbose=True):
    """A full power cycle. Returns seconds from power-on to *IDN? answering.

    On success the caller has one fresh UI build available.
    """
    min_off = PLUG_MIN_OFF_S if min_off is None else min_off
    last = None
    for attempt in range(1, tries + 1):
        try:
            if verbose:
                print(f'power cycle attempt {attempt}/{tries}: off ...')
            down = off(ip=ip, dry=dry)
            if verbose:
                print(f'  down after {down:.1f} s; holding {min_off:.0f} s')
            if not dry:
                time.sleep(min_off)
            up = on(ip=ip, dry=dry)
            if verbose:
                print(f'  up after {up:.1f} s')
            return up
        except PowerError as e:
            last = e
            if verbose:
                print(f'  FAILED: {e}')
            # A retry ceiling matters: without one, a plug that has fallen off
            # the HomeKit network turns into an infinite loop that looks like a
            # long-running test.
    raise PowerError(f'power cycle failed after {tries} attempts: {last}')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('action', choices=['on', 'off', 'cycle', 'status'])
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--ip', default=DMM_IP)
    a = ap.parse_args()

    if a.action == 'status':
        print('up' if responds(a.ip) else 'down')
        return 0
    try:
        if a.action == 'on':
            print(f'up after {on(ip=a.ip, dry=a.dry):.1f} s')
        elif a.action == 'off':
            print(f'down after {off(ip=a.ip, dry=a.dry):.1f} s')
        else:
            print(f'cycled, up after {cycle(ip=a.ip, dry=a.dry):.1f} s')
    except PowerError as e:
        print(f'ERROR: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
