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
