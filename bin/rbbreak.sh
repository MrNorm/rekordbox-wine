#!/usr/bin/env bash
#
# rbbreak.sh — non-interactive breakpoint harness for a Windows PE running
#              under Wine (built for rekordbox.exe, proven on a toy PE).
#
# Breaks on a list of ABSOLUTE addresses, logs every hit with a timestamp, the
# four Microsoft-x64 integer argument registers (rcx, rdx, r8, r9), the caller,
# any argument that turns out to point at a readable C string, and — unless
# --no-ret — the return value in rax when the function returns. Then detaches
# cleanly and verifies it left no breakpoint bytes behind.
#
#   ./rbbreak.sh -p <unix-pid> -d 30 0x1423a5210 0x1423aaf40
#   ./rbbreak.sh --find rekordbox.exe -d 60 -o /tmp/hits.tsv 0x1423ab020
#
# WHY GDB AND NOT WINEDBG — measured, see the notes at the bottom of this file.
#
# SAFETY CONTRACT
#   * gdb is only ever stopped with SIGTERM, never SIGKILL. A SIGKILLed gdb
#     leaves 0xCC bytes in the target's .text and the target dies on the next
#     hit with an unhandled 0x80000003. This script traps EXIT/INT/TERM/HUP and
#     always drives gdb down with SIGTERM.
#   * The original byte at every breakpoint address is read before attaching and
#     re-read after detaching. A mismatch is reported loudly and, with --repair,
#     written back.
#   * The target is never killed, never suspended for longer than a hit, and
#     never launched by this script. It must already be running.
#
set -uo pipefail

SELF="$(readlink -f "$0")"
WORK="$(dirname "$SELF")"
PYMOD="$WORK/.rbbreak_gdb.py"

PID=""; FIND=""; DUR=30; OUT=""; MAXHITS=0; CHASE=1; DRY=0; REPAIR=0
SEGV="nostop noprint pass"; GDB="${GDB:-gdb}"; SUDO="sudo -n"

die(){ echo "rbbreak: $*" >&2; exit 2; }
usage(){ sed -n '2,32p' "$SELF"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pid)     PID="$2"; shift 2;;
    --find)       FIND="$2"; shift 2;;
    -d|--duration)DUR="$2"; shift 2;;
    -o|--out)     OUT="$2"; shift 2;;
    -n|--max-hits)MAXHITS="$2"; shift 2;;
    --no-ret)     CHASE=0; shift;;
    --catch-segv) SEGV="stop print nopass"; shift;;
    --repair)     REPAIR=1; shift;;
    --dry-run)    DRY=1; shift;;
    -h|--help)    usage;;
    --targets)    sed -n '/^# RECOMMENDED BREAKPOINTS/,/^# END TARGETS/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0;;
    -*)           die "unknown option $1";;
    *)            break;;
  esac
done

SPECS=("$@")
[[ ${#SPECS[@]} -gt 0 ]] || usage
# a spec is ADDR or ADDR:entry or ADDR:probe — the shell side only wants ADDR
ADDRS=(); for s in "${SPECS[@]}"; do ADDRS+=("${s%%:*}"); done

# ---------------------------------------------------------------- find target
if [[ -z "$PID" ]]; then
  [[ -n "$FIND" ]] || die "need -p <pid> or --find <exe-name>"
  mapfile -t cands < <(pgrep -f -- "$FIND" | while read -r p; do
      [[ -r "/proc/$p/maps" ]] || continue
      grep -qi -- "$FIND" "/proc/$p/maps" 2>/dev/null && echo "$p"
  done)
  [[ ${#cands[@]} -eq 1 ]] || die "--find matched ${#cands[@]} processes: ${cands[*]:-none}"
  PID="${cands[0]}"
fi
[[ -d "/proc/$PID" ]] || die "no such process $PID"

NTHREADS=$(ls "/proc/$PID/task" 2>/dev/null | wc -l)
COMM=$(tr -d '\0' < "/proc/$PID/comm" 2>/dev/null)
: "${OUT:=$WORK/rbbreak-$(date +%Y%m%dT%H%M%S)-$PID.tsv}"

$SUDO true 2>/dev/null || die "passwordless sudo required (kernel.yama.ptrace_scope=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null))"

# ------------------------------------------------- map check + original bytes
# Reads /proc/PID/mem directly: confirms each address is mapped, executable, and
# tells us which module it belongs to, so a wrong image base is caught BEFORE
# any 0xCC is written.
readbytes(){ # $1=pid  $2..=addrs -> "addr byte perms module+offset"
  $SUDO python3 - "$1" "${@:2}" <<'PY'
import sys
pid=int(sys.argv[1]); addrs=[int(a,0) for a in sys.argv[2:]]
maps=[]
for ln in open(f"/proc/{pid}/maps"):
    a,rest=ln.split(" ",1); lo,hi=a.split("-")
    parts=rest.split(None,4)
    maps.append((int(lo,16),int(hi,16),parts[0],(parts[4].strip() if len(parts)>4 else "")))
# Wine maps a PE's header page file-backed (so /proc/maps carries the path) but
# the SECTIONS are anonymous. Attribute an address to the nearest preceding
# file-backed .exe/.dll mapping instead of to its own map line.
mods=sorted([m for m in maps if m[3].lower().endswith((".exe",".dll",".so"))])
mem=open(f"/proc/{pid}/mem","rb",0)
for ad in addrs:
    hit=[m for m in maps if m[0]<=ad<m[1]]
    if not hit:
        print("%#x UNMAPPED - -"%ad); continue
    lo,hi,perms,_=hit[0]
    owner="-"
    prev=[m for m in mods if m[0]<=ad]
    if prev:
        base=prev[-1][0]
        owner="%s+%#x@%#x"%(prev[-1][3].rsplit("/",1)[-1], ad-base, base)
    try:
        mem.seek(ad); b=mem.read(1)[0]
        print("%#x %02x %s %s"%(ad,b,perms,owner))
    except Exception:
        print("%#x READFAIL %s %s"%(ad,perms,owner))
PY
}

echo "rbbreak: pid=$PID comm=$COMM threads=$NTHREADS duration=${DUR}s out=$OUT"
BEFORE=$(readbytes "$PID" "${ADDRS[@]}") || die "cannot read /proc/$PID/mem"
echo "$BEFORE" | while read -r a b p m; do printf '  %-14s byte=%-8s %-4s %s\n' "$a" "$b" "$p" "$m"; done
if grep -q UNMAPPED <<<"$BEFORE"; then
  die "one or more addresses are not mapped in pid $PID — wrong image base or wrong process"
fi
if ! grep -q 'x' <<<"$(echo "$BEFORE" | awk '{print $3}')"; then
  echo "rbbreak: WARNING none of the addresses are in an executable mapping" >&2
fi

# ------------------------------------------------------------ the gdb payload
cat > "$PYMOD" <<'PYEOF'
# loaded inside gdb. Everything it needs arrives through the environment so the
# script text is identical from run to run and can be diffed.
import gdb, os, time, struct

T0      = time.time()
# "ADDR" or "ADDR:entry" -> function entry: log args, chase the return value.
# "ADDR:probe"           -> arbitrary instruction: log rax/rbx too, no return
#                           chasing and no caller (rsp does not hold one there).
SPECS   = []
for x in os.environ["RBB_ADDRS"].split(","):
    a, _, m = x.partition(":")
    SPECS.append((int(a, 0), (m or "entry")))
ADDRS   = [a for a, _ in SPECS]
LOGPATH = os.environ["RBB_LOG"]
MAXHITS  = int(os.environ.get("RBB_MAXHITS", "0"))
CHASE    = os.environ.get("RBB_RET", "1") == "1"
DEADLINE = float(os.environ.get("RBB_DEADLINE", "0"))

log = open(LOGPATH, "a", buffering=1)
hits = 0

def emit(*a):
    log.write("\t".join(str(x) for x in a) + "\n")

def ts():
    return "%.6f" % (time.time() - T0)

def peek_str(inf, ptr, maxlen=96):
    """If ptr points at a printable NUL-terminated string, return it."""
    if ptr < 0x1000 or ptr > 0x7fffffffffff:
        return ""
    try:
        raw = inf.read_memory(ptr, maxlen).tobytes()
    except Exception:
        return ""
    end = raw.find(b"\x00")
    if end <= 0:
        # maybe UTF-16LE (Windows strings usually are)
        if len(raw) >= 4 and raw[1] == 0 and raw[3] == 0:
            w = raw.decode("utf-16-le", "ignore").split("\x00")[0]
            return "u:" + w if w and all(32 <= ord(c) < 127 for c in w) else ""
        return ""
    s = raw[:end]
    if all(32 <= c < 127 for c in s):
        return "a:" + s.decode()
    return ""

_dead = []

def _reap():
    """Delete retired return-breakpoints from gdb's main loop, never from
    inside a stop() callback (deleting a breakpoint from its own stop handler
    is documented as unsafe)."""
    while _dead:
        try:
            _dead.pop().delete()
        except Exception:
            pass

class RetBP(gdb.Breakpoint):
    """One-shot, thread-scoped breakpoint on the caller's return address.

    gdb only auto-retires a `temporary` breakpoint when it actually STOPS, and
    ours never does (stop() returns False so the target keeps running). Left
    alone they pile up and every later return re-reports every earlier call —
    measured: 3540 RET lines for 118 HITs. So disable on first fire, then reap.
    """
    def __init__(self, addr, gthread, tag, seq):
        super().__init__("*%#x" % addr, gdb.BP_BREAKPOINT,
                         internal=True, temporary=False)
        self.thread = gthread
        self.silent = True
        self.tag = tag
        self.seq = seq
    def stop(self):
        try:
            rax = int(gdb.selected_frame().read_register("rax")) & (2**64 - 1)
        except Exception:
            rax = -1
        emit(ts(), "RET", self.tag, self.seq, gdb.selected_thread().global_num,
             "rax=%#x" % rax, rax)
        self.enabled = False          # takes the 0xCC out immediately
        _dead.append(self)
        gdb.post_event(_reap)
        return False          # never stop the world for a return value

class EntryBP(gdb.Breakpoint):
    def __init__(self, addr, mode):
        super().__init__("*%#x" % addr, gdb.BP_BREAKPOINT)
        self.silent = True
        self.addr = addr
        self.mode = mode
        self.tag = "%#x" % addr
    def stop(self):
        global hits
        hits += 1
        seq = hits
        try:
            f   = gdb.selected_frame()
            inf = gdb.selected_inferior()
            r   = {n: int(f.read_register(n)) & (2**64 - 1)
                   for n in ("rax", "rbx", "rcx", "rdx", "r8", "r9", "rsp")}
            th  = gdb.selected_thread()
            caller = 0
            if self.mode == "entry":
                try:
                    caller = struct.unpack("<Q", inf.read_memory(r["rsp"], 8).tobytes())[0]
                except Exception:
                    caller = 0
            strs = []
            for n in ("rcx", "rdx", "r8", "r9"):
                s = peek_str(inf, r[n])
                if s:
                    strs.append("%s=%s" % (n, s))
            emit(ts(), "HIT", self.tag, seq, th.global_num,
                 "rcx=%#x" % r["rcx"], "rdx=%#x" % r["rdx"],
                 "r8=%#x"  % r["r8"],  "r9=%#x"  % r["r9"],
                 "rax=%#x" % r["rax"], "rbx=%#x" % r["rbx"],
                 "eax=%d"  % struct.unpack("<i", struct.pack("<I", r["rax"] & 0xffffffff))[0],
                 "caller=%#x" % caller,
                 " ".join(strs))
            if CHASE and caller and self.mode == "entry":
                RetBP(caller, th.global_num, self.tag, seq)
        except Exception as e:
            emit(ts(), "ERR", self.tag, seq, repr(e))
        if MAXHITS and hits >= MAXHITS:
            emit(ts(), "LIMIT", MAXHITS)
            return True       # stops -> the drive loop sees it and detaches
        # The drive loop can only test the clock between `continue` calls, and
        # `continue` never returns while stop() keeps saying False. So the
        # deadline has to be enforced HERE, at a hit.
        if DEADLINE and time.time() >= T0 + DEADLINE:
            emit(ts(), "LIMIT", "deadline")
            return True
        return False

for a, mode in SPECS:
    try:
        EntryBP(a, mode)
        emit(ts(), "ARM", "%#x" % a, "ok", mode)
    except Exception as e:
        emit(ts(), "ARM", "%#x" % a, "FAILED", mode, repr(e))
emit(ts(), "READY", "threads=%d" % len(gdb.selected_inferior().threads()))

# ---------------------------------------------------------------- drive loop
# A single `continue` is not enough: ANY stop gdb does not auto-resume (a stray
# SIGSTOP left by an earlier ptrace session, a signal we did not list, a thread
# exit) ends the run silently. Measured: one leftover SIGSTOP ended a 194-thread
# run after 0 hits. So re-continue until the deadline, the hit limit, or the
# process going away — and record WHY we stopped.
end_at = (T0 + DEADLINE) if DEADLINE else float("inf")
spurious = 0
reason = "deadline"
while True:
    if hits and MAXHITS and hits >= MAXHITS:
        reason = "max-hits"; break
    if time.time() >= end_at:
        reason = "deadline"; break
    try:
        gdb.execute("continue")
    except gdb.error as e:
        reason = "gdb-error: %s" % e; break
    except KeyboardInterrupt:
        reason = "interrupt"; break
    if MAXHITS and hits >= MAXHITS:
        reason = "max-hits"; break
    spurious += 1
    if spurious > 500:
        reason = "too many non-breakpoint stops"; break
emit(ts(), "DONE", reason, "hits=%d" % hits, "resumes=%d" % spurious)
log.flush()
PYEOF

JOINED=$(IFS=,; echo "${SPECS[*]}")

if [[ $DRY -eq 1 ]]; then
  echo "--- would run ---"
  echo "RBB_ADDRS=$JOINED RBB_LOG=$OUT RBB_MAXHITS=$MAXHITS RBB_RET=$CHASE"
  echo "$SUDO timeout -s TERM $DUR $GDB -q -batch ... -p $PID"
  echo "--- gdb python module at $PYMOD ---"
  exit 0
fi

: > "$OUT"
printf '# rbbreak pid=%s comm=%s threads=%s addrs=%s started=%s\n' \
       "$PID" "$COMM" "$NTHREADS" "$JOINED" "$(date -Is)" >> "$OUT"

GDBPID=""
cleanup(){
  local rc=$?
  if [[ -n "$GDBPID" ]] && kill -0 "$GDBPID" 2>/dev/null; then
    echo "rbbreak: stopping gdb ($GDBPID) with SIGTERM — never SIGKILL" >&2
    $SUDO kill -TERM "$GDBPID" 2>/dev/null
    for _ in $(seq 100); do kill -0 "$GDBPID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$GDBPID" 2>/dev/null; then
      echo "rbbreak: gdb did not exit on SIGTERM; sending a second SIGTERM" >&2
      $SUDO kill -TERM "$GDBPID" 2>/dev/null; sleep 2
    fi
  fi
  return $rc
}
trap cleanup EXIT INT TERM HUP

# `timeout -s TERM` is the duration bound. SIGTERM is the *safe* stop: gdb's
# own handler removes every breakpoint and detaches (measured).
$SUDO env RBB_ADDRS="$JOINED" RBB_LOG="$OUT" RBB_MAXHITS="$MAXHITS" RBB_RET="$CHASE" \
  RBB_DEADLINE="$DUR" \
  timeout -s TERM "$((DUR + 15))" "$GDB" -q -batch -nx \
    -ex "set confirm off" \
    -ex "set pagination off" \
    -ex "set height 0" \
    -ex "set width 0" \
    -ex "set print thread-events off" \
    -ex "set detach-on-fork on" \
    -ex "set follow-fork-mode parent" \
    -ex "handle SIGUSR1 nostop noprint pass" \
    -ex "handle SIGUSR2 nostop noprint pass" \
    -ex "handle SIGPIPE nostop noprint pass" \
    -ex "handle SIG33 nostop noprint pass" \
    -ex "handle SIG34 nostop noprint pass" \
    -ex "handle SIGSEGV $SEGV" \
    -ex "handle SIGCHLD nostop noprint pass" \
    -ex "handle SIGSTOP nostop noprint nopass" \
    -ex "attach $PID" \
    -ex "source $PYMOD" \
    -ex "detach" \
    -ex "quit" > "$OUT.gdb" 2>&1 &
GDBPID=$!
wait "$GDBPID"; GRC=$?
GDBPID=""

# ------------------------------------------------------------------- verify
sleep 0.5
if [[ ! -d "/proc/$PID" ]]; then
  echo "rbbreak: FATAL — target $PID is gone. Check $OUT.gdb" >&2
  exit 3
fi
AFTER=$(readbytes "$PID" "${ADDRS[@]}")
DAMAGED=0
while read -r a bafter _; do
  bbefore=$(awk -v A="$a" '$1==A{print $2}' <<<"$BEFORE")
  if [[ "$bafter" != "$bbefore" ]]; then
    echo "rbbreak: DAMAGE at $a — was $bbefore, now $bafter" >&2
    DAMAGED=1
    if [[ $REPAIR -eq 1 ]]; then
      $SUDO python3 -c "
import sys
m=open('/proc/$PID/mem','r+b',0); m.seek($a); m.write(bytes([0x$bbefore]))
print('repaired $a -> 0x$bbefore')"
    fi
  fi
done <<<"$AFTER"

HITS=$(grep -c $'\tHIT\t' "$OUT" 2>/dev/null || echo 0)
RETS=$(grep -c $'\tRET\t' "$OUT" 2>/dev/null || echo 0)
echo "rbbreak: gdb rc=$GRC  hits=$HITS  returns=$RETS  target alive=yes  damage=$DAMAGED"
echo "rbbreak: log $OUT   gdb transcript $OUT.gdb"
if [[ $DAMAGED -ne 0 ]]; then
  [[ $REPAIR -eq 1 ]] || echo "rbbreak: re-run with --repair to restore the original bytes" >&2
  exit 4
fi
exit 0

# ---------------------------------------------------------------------------
# WHY GDB. Measured on this machine (see the report), per-breakpoint-hit cost,
# each hit logging four argument registers and dereferencing one of them:
#
#   backend                              1 thread     194 threads
#   winedbg --command (Wine debug API)   3.07 ms      5.87 ms
#   gdb over winedbg --gdb proxy         2.04 ms      22.4 ms
#   gdb native (ptrace, sudo)            0.135 ms     3.73 ms      <- this
#
# winedbg cannot do the job anyway: it has no breakpoint command lists, no
# conditions, no loops and no way to set a breakpoint at a computed address, so
# it cannot capture a return value, and a run of N hits needs a command file
# with N literal `cont` lines. Its one advantage is `bt`, which unwinds PE
# frames properly from .pdata — use `winedbg --command 'break *ADDR
# <cont> bt <detach>' <windows-pid>` when you want a full call stack.

# RECOMMENDED BREAKPOINTS — rekordbox 7.2.18, image base 0x140000000
#
# The base is not an assumption: /proc/<pid>/maps of the running rekordbox.exe
# shows 140000000-140001000 backed by the exe itself, and the first byte at
# every address below is identical in the live process and in the file on disk,
# so the static analysis addresses are live-valid and nothing is unpacked at
# runtime. All six T05 function addresses are EXACT RUNTIME_FUNCTION entries in
# .pdata (168,504 entries parsed).
#
# TIER 1 — the USB gate. This is where the DDJ-400 is thrown away.
#   0x1423aaf40            entry   the gate. rcx = model id (32-bit), rdx = ptr
#                                  to the name object. Return value in rax is
#                                  the MidiMap object, or NULL if it refused.
#   0x1423aaf68            probe   the CALL into the model factory; rcx/rdx are
#                                  the factory's own arguments at this point.
#   0x1423aafaa:probe      probe   *** THE DECISIVE VALUE ***. eax here is the
#                                  result of the USBDeviceValidation vtable+0x18
#                                  probe, the number logged as "bcdVersion=%04X".
#                                  The gate is literally `shr ebx,0x1f` on it:
#                                  eax >= 0 -> accept, eax < 0 -> destroy+NULL.
#   0x1423aafc7:probe      probe   the FAILURE arm — deleting destructor. A hit
#                                  here means the probe came back negative.
#   0x1423aafef:probe      probe   the SUCCESS arm. A hit here means the gate
#                                  passed and the device object survives.
#
#   Between 0x1423aaf94 and 0x1423aafa8 sits __RTDynamicCast with type
#   descriptors .?AVMidiMap@djplay@@ -> .?AVUSBDeviceValidation@djplay@@ (read
#   out of the image, not guessed), and 0x142a004e0 is the logger that formats
#   "bcdVersion = %04X" (string at 0x143b72220).
#
# TIER 2 — the surrounding state machine.
#   0x1423ab020            entry   56-entry model factory. rcx = model id.
#                                  rax = the MidiMap<Model> it built, or NULL.
#   0x1423b7e30            entry   djplay::MidiMapDDJ400 ctor. A hit here proves
#                                  the name match succeeded and the DDJ-400
#                                  object really was constructed.
#   0x1423a5210            entry   djplay::DeviceMidi::openDevice.
#   0x1423a4d40            entry   djplay::DeviceMidi ctor.
#   0x1422bc470            entry   MidiConnect — the ONLY caller of that ctor,
#                                  and the place the .midi.csv gate is applied.
#
# A first run that answers the open question in one shot:
#
#   ./rbbreak.sh --find rekordbox.exe -d 120 \
#       0x1423b7e30 0x1423aaf40 0x1423aafaa:probe \
#       0x1423aafc7:probe 0x1423aafef:probe
#
#   ctor hit + 0x1423aafc7 hit  -> the object is built and the USB probe refuses
#                                  it; read eax at 0x1423aafaa for the number.
#   ctor never hit              -> the failure is earlier, upstream of the gate.
#   0x1423aafef hit             -> the gate passes and the blocker has moved on.
#
# For a full PE call stack at any of these, use winedbg instead — it unwinds
# from .pdata and gdb cannot:
#   winedbg --command "$(printf 'break *0x1423aaf40\ncont\nbt\ninfo regs\ndetach\n')" <WINDOWS-PID>
# END TARGETS
