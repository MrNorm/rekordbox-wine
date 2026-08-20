#!/usr/bin/env python3
"""Triage a Wine log: what loaded, what failed, what to look at first.

Also provides --normalise, which strips run-to-run noise (addresses, pids,
thread ids, timestamps) so two runs can be diffed meaningfully. Without that
every diff is 100% churn and tells you nothing.
"""
import json
import os
import re
import sys
from collections import Counter

# Ordered: the first pattern that matches a line wins its category.
PATTERNS = [
    ("unhandled_exception", re.compile(r"wine: Unhandled (\w+ )?exception|Unhandled exception:")),
    # Anchored against surrounding hex: an unanchored "c0000005" matches inside
    # ordinary hex arguments (measured: NtQueryValueKey(...,6c00000050,...) was
    # reported as 12 access violations in a log with zero real faults).
    ("fastfail",            re.compile(r"(?<![0-9a-fA-F])c0000409(?![0-9a-fA-F])"
                                       r"|STATUS_STACK_BUFFER_OVERRUN|__fastfail")),
    ("access_violation",    re.compile(r"(?<![0-9a-fA-F])c0000005(?![0-9a-fA-F])"
                                       r"|EXCEPTION_ACCESS_VIOLATION")),
    ("missing_export",      re.compile(r"err:module:.*(not found|failed to (import|load)|no longer|imported from)")),
    ("module_init_failed",  re.compile(r"err:module:.*(initialization|DllMain).*failed")),
    ("driver_load",         re.compile(r"NtLoadDriver|CreateService.*KERNEL_DRIVER|winedevice")),
    ("d3d_vulkan",          re.compile(r"err:(d3d|vulkan|dxgi|wgl)")),
    ("ole_com",             re.compile(r"err:ole|CoCreateInstance.*failed")),
    ("winsock_tls",         re.compile(r"err:(winsock|secur32|schannel)")),
    ("registry",            re.compile(r"err:reg:")),
    ("other_err",           re.compile(r"^\s*\d*:?err:")),
]

LOADDLL = re.compile(r"trace:loaddll:.*?(?:Loaded|Modend)\s+L?[\"']?([^\"']+?)[\"']?\s")
SYSCALL = re.compile(r"trace:syscall:[^ ]* (\w+)")
FIXME = re.compile(r"fixme:([a-z_0-9]+):(\w+)")

NORM = [
    (re.compile(r"0x[0-9a-fA-F]{4,}"), "0xADDR"),
    (re.compile(r"\b[0-9A-Fa-f]{8,16}\b"), "HEX"),
    (re.compile(r"^\s*[0-9a-f]{3,5}:"), "TID:"),
    (re.compile(r"\d{2}:\d{2}:\d{2}"), "TIME"),
    (re.compile(r"\bpid \d+"), "pid N"),
]


def normalise(path):
    out = []
    with open(path, errors="replace") as fh:
        for line in fh:
            for rx, rep in NORM:
                line = rx.sub(rep, line)
            out.append(line.rstrip())
    return out


def classify(path, outdir):
    cats = Counter()
    first = {}
    modules, syscalls, fixmes = [], Counter(), Counter()
    tail = []
    total = 0

    with open(path, errors="replace") as fh:
        for line in fh:
            total += 1
            tail.append(line.rstrip())
            if len(tail) > 60:
                tail.pop(0)

            m = LOADDLL.search(line)
            if m:
                modules.append(os.path.basename(m.group(1)).lower())
            m = SYSCALL.search(line)
            if m:
                syscalls[m.group(1)] += 1
            m = FIXME.search(line)
            if m:
                fixmes[f"{m.group(1)}:{m.group(2)}"] += 1

            for name, rx in PATTERNS:
                if rx.search(line):
                    cats[name] += 1
                    first.setdefault(name, line.rstrip()[:400])
                    break

    mods = sorted(set(modules))
    # Modules that tell us what kind of app surface we're dealing with.
    tells = {
        "embedded_browser": [m for m in mods if any(
            k in m for k in ("libcef", "webview2", "msedgewebview", "chrome_elf", "cef"))],
        "dotnet":  [m for m in mods if any(k in m for k in ("mscoree", "clr.dll", "coreclr"))],
        "d3d":     [m for m in mods if any(k in m for k in ("d3d9", "d3d11", "d3d12", "dxgi", "dxvk"))],
        "audio":   [m for m in mods if any(k in m for k in ("mmdevapi", "winepulse", "winealsa", "audioses"))],
        "storage": [m for m in mods if any(k in m for k in ("setupapi", "mountmgr", "cfgmgr32"))],
    }

    res = {
        "log_lines": total,
        "categories": dict(cats),
        "first_hit": first,
        "module_count": len(mods),
        "modules": mods,
        "surface_tells": tells,
        "top_syscalls": syscalls.most_common(15),
        "top_fixmes": fixmes.most_common(15),
        "tail": tail,
    }
    with open(os.path.join(outdir, "classify.json"), "w") as fh:
        json.dump(res, fh, indent=1)

    md = [f"**log**: {total} lines, {len(mods)} modules loaded", ""]
    if cats:
        md.append("**failure categories**")
        for k, v in cats.most_common():
            md.append(f"- `{k}` ×{v}")
            if k in first:
                md.append(f"  - first: `{first[k][:200]}`")
    else:
        md.append("_no error lines matched_")
    md.append("")
    for k, v in tells.items():
        if v:
            md.append(f"**{k}**: {', '.join(v[:6])}")
    if fixmes:
        md.append("")
        md.append("**top fixmes**: " + ", ".join(f"{k}×{v}" for k, v in fixmes.most_common(6)))
    with open(os.path.join(outdir, "classify.md"), "w") as fh:
        fh.write("\n".join(md) + "\n")
    return res


if __name__ == "__main__":
    if sys.argv[1] == "--normalise":
        print("\n".join(normalise(sys.argv[2])))
    else:
        log, outdir = sys.argv[1], sys.argv[2]
        if not os.path.exists(log):
            sys.exit(f"no log at {log}")
        classify(log, outdir)
