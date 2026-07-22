# GoodWe GW8KN-ET field pilot

Version 1.0.2 is read-only. It grants only `modbus.read` and must not write
register 47040 or any other register. Use it only with an exact commit and
artifact hash outside the stable channel until this pilot passes.

## Required setup facts

Record the inverter model, HK3000 presence, dongle model, inverter, ARM, DSP
and dongle firmware, network type, Modbus unit id and FTW version. Mask the IP
address and serial number before adding logs to a public pull request.

Set the host's Modbus capability unit id to 247 unless the site proves another
id. The Lua config cannot inspect or validate the host's unit id. Select the
new register map by name:

```yaml
config:
  profile: gw8kn-et-hk3000
```

Do not choose a profile from a value that looks plausible. The same addresses
have different widths and meanings in the two source maps.

## Successful poll batches

All reads use holding registers and Modbus FC03. The driver emits nothing until
all eight batches succeed.

The GW8KN-ET profile makes eight transactions per successful poll. The input
driver made 13 without a detected battery and 15 with one. The legacy
`community-v1` profile keeps its 22 known read boundaries. An empty old config
selects only that legacy profile; an explicit unknown profile fails init.

| Start | Count | Used addresses | Ignored gaps |
|---:|---:|---|---|
| 35107 | 4 | 35107, 35108, 35110 | 35109 |
| 35123 | 1 | 35123 | none |
| 35125 | 11 | 35125, 35130, 35135 | 35126–35129, 35131–35134 |
| 35138 | 3 | 35138, 35140 | 35139 |
| 35145 | 13 | 35145, 35151, 35157 | 35146–35150, 35152–35156 |
| 35164 | 5 | 35164, 35166, 35168 | 35165, 35167 |
| 35178 | 6 | 35178, 35180, 35182, 35183 | 35179, 35181 |
| 35195 | 5 | 35195–35196, 35198–35199 | 35197 |

The gaps stay within each source-reported register block. The batch layout has
only synthetic replay coverage until the field pilot records raw responses.

## Pass checks

1. Capture at least ten full snapshots during PV generation and grid import.
   Capture export and battery charge or discharge when those states occur.
2. Compare raw batch words with each emitted snapshot. Meter import must be
   positive, export negative, PV negative, battery charge positive, battery
   discharge negative and SoC within 0..1. Energy counters must not fall.
3. Compare the same energy interval with SEMS. Set the allowed difference
   before the test; the proposed stable limit is 10 percent.
4. Block only the inverter network path for more than 90 seconds. Failed reads
   must emit no zero or partial snapshot. FTW must mark the driver offline and
   idle or release batteries, then recover without a driver or dongle restart.
5. Hard-power-cycle only the FTW controller three times. Leave the inverter and
   dongle powered. Each run must recover without a dongle power cycle, without
   reconnect spam and without fresh status before a full snapshot. Record time
   to recovery. The proposed stable limit is five minutes for all three runs.
6. Run for at least 24 hours in daylight. Check for silent zero periods,
   false freshness, unexplained energy gaps and any Modbus write attempt.

Stable stops on any write, wrong register width, partial or zero snapshot after
an error, false `LastSuccess`, reconnect loop, blocked safety action or need for
a dongle power cycle. Add masked fixtures, three reboot timelines and the
24-hour result to the draft pull request before stable promotion.
