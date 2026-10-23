#!/usr/bin/env python3
"""Cuts an xctrace recording of the energy scenario into its states and writes summary.md.

    python3 -I scripts/device-energy-summary.py <out-dir>   # reads energy.trace, energy.log, ref.txt

States come from the host's energy.log (epoch ms) mapped onto the trace clock by the trace's start date.
The recording is system-wide: the renderer's I/O runs in the audio daemons, not the app, so the paused
state's answer is in their CPU and Time Profiler samples.
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime
from pathlib import Path

# A launched recording names the app by its display name, a system-wide one by its executable.
APP = "Playback Device Tests|DeviceTestHost"
# Processes that serve audio hardware for apps on iOS.
DAEMONS = ["audiomxd", "mediaserverd", "coreaudiod", "audioaccessoryd"]
AUDIO_IO = re.compile(r"AURemoteIO|AudioDeviceIOProc|HALC_|HALB_|MEMixerChannel|MXSession|AQ(Mixer|Server)|IOProc|SRC|AudioConverter|AUGraph|AudioQueue")
STATES = ["playing-1x", "playing-1.5x", "paused", "idle", "avaudioplayer"]
EDGE_SECONDS = 5  # trimmed from each end of a state: transitions and the profiler settling


def xctrace(*args):
    return subprocess.run(["xcrun", "xctrace", "export", *args], check=True, capture_output=True, text=True).stdout


def table(trace, schema):
    root = ET.fromstring(xctrace("--input", str(trace), "--xpath", f'/trace-toc/run[1]/data/table[@schema="{schema}"]'))
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}
    return ids, [[ids.get(c.get("ref"), c) if c.get("ref") else c for c in row] for row in root.iter("row")]


def number(e):
    try:
        return float(e.text)
    except (TypeError, ValueError):
        return None


def named(e, name):
    return re.fullmatch(name, re.sub(r" \(\d+\)$", "", e.get("fmt", ""))) is not None


def windows(trace, log):
    start = datetime.fromisoformat(ET.fromstring(xctrace("--input", str(trace), "--toc")).find(".//start-date").text).timestamp()
    marks = {}
    for line in log.read_text().splitlines():
        _, ms, name = line.split()
        marks[name] = int(ms) / 1000 - start
    order = ["start", *STATES, "done"]
    return {s: (marks[s] + EDGE_SECONDS, marks[order[i + 2]] - EDGE_SECONDS) for i, s in enumerate(order[1:-1])
            if s in marks and order[i + 2] in marks}


def activity(trace, spans):
    # cpu-total and idle-wakeups are cumulative: a state's rate is the change across it.
    _, rows = table(trace, "activity-monitor-process-live")
    out = {}
    for name in [APP, *DAEMONS]:
        series = [(number(r[0]) / 1e9, number(r[7]) / 1e9, number(r[18])) for r in rows
                  if named(r[1], name) and number(r[7]) is not None]
        # A process that did nothing gets no rows, so read each total as of the last row at or before the instant.
        def at(t):
            return next((s for s in reversed(series) if s[0] <= t), None)
        for state, (a, b) in spans.items():
            first, last = at(a), at(b)
            if first and last:
                out[name, state] = ((last[1] - first[1]) / (b - a) * 100, (last[2] - first[2]) / (b - a))
    return out


def power(trace, spans):
    _, rows = table(trace, "ProcessSubsystemPowerImpact")
    values = [(number(r[0]) / 1e9, number(r[4])) for r in rows if named(r[2], APP) and number(r[4]) is not None]
    out = {}
    for state, (a, b) in spans.items():
        inside = [v for t, v in values if a <= t <= b]
        out[state] = sum(inside) / len(inside) if inside else None
    return out


def profile(trace, spans):
    ids, rows = table(trace, "time-profile")
    counts, frames = Counter(), {}
    for r in rows:
        t = number(r[0]) / 1e9
        process = re.sub(r" \(\d+\)$", "", r[2].get("fmt", ""))
        if re.fullmatch(APP, process):
            process = "app"
        for state, (a, b) in spans.items():
            if a <= t <= b:
                counts[process, state] += 1
                hit = [n for n in (ids.get(f.get("ref"), f).get("name", "") for f in r[6]) if AUDIO_IO.search(n)]
                if hit:
                    frames.setdefault(state, Counter())[process, hit[0]] += 1
    return counts, frames


def main(out_dir):
    out = Path(out_dir)
    spans = windows(out / "energy.trace", out / "energy.log")
    cpu = activity(out / "energy.trace", spans)
    impact = power(out / "energy.trace", spans)
    counts, frames = profile(out / "energy.trace", spans)
    ref = (out / "ref.txt").read_text().strip() if (out / "ref.txt").exists() else "?"
    lines = [f"# Energy at {ref[:7]}", "",
             f"Elise's iPhone, system-wide recording, {EDGE_SECONDS} s trimmed from each end of each state. "
             "CPU is % of one core; wakeups are idle wakeups per second; samples are Time Profiler samples (1 ms).", "",
             "| State | App CPU % | App wakeups/s | App power CPU impact | App samples | "
             + " | ".join(f"{d} CPU %" for d in DAEMONS) + " |",
             "|---|---|---|---|---|" + "---|" * len(DAEMONS)]
    for s in STATES:
        if (APP, s) not in cpu:
            continue
        c, w = cpu[APP, s]
        i = impact[s]
        daemons = " | ".join(f"{cpu[d, s][0]:.1f}" if (d, s) in cpu else "-" for d in DAEMONS)
        lines.append(f"| {s} | {c:.1f} | {w:.0f} | {'n/a' if i is None else f'{i:.1f}'} | {counts['app', s]} | {daemons} |")
    lines += ["", "## Audio I/O frames in Time Profiler samples (process, frame: samples)", ""]
    for s in STATES:
        top = ", ".join(f"{p} {n} x{k}" for (p, n), k in frames.get(s, Counter()).most_common(5))
        lines.append(f"- {s}: {top or 'none'}")
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


main(sys.argv[1])
