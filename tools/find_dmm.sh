#!/bin/bash
# Poll subnet for Keithley: web (80) + SCPI (5025), plus Tektronix OUI 08:00:11 in ARP
for round in $(seq 1 40); do
  # prime ARP cache across subnet
  for i in $(seq 1 254); do (ping -c 1 -W 200 10.0.1.$i >/dev/null 2>&1) & done
  wait
  HITS=$(arp -a | grep -iE '08:00:11|0:0:11' | grep -oE '10\.0\.1\.[0-9]+' | sort -u)
  if [ -n "$HITS" ]; then
    for h in $HITS; do
      if nc -z -G 2 -w 2 $h 80 2>/dev/null; then
        echo "ROUND $round FOUND_TEK_WEB $h"
      else
        echo "ROUND $round tek-oui-no-web $h"
      fi
    done
  fi
  # also catch any new port-80 host
  for i in $(seq 1 254); do (nc -z -G 1 -w 1 10.0.1.$i 80 2>/dev/null && echo "ROUND $round web80 10.0.1.$i") & done
  wait
  for i in $(seq 1 254); do (nc -z -G 1 -w 1 10.0.1.$i 5025 2>/dev/null && echo "ROUND $round SCPI5025 10.0.1.$i") & done
  wait
  sleep 5
done
