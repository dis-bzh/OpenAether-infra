"""Parse an audit rules file with libaudit itself (no kernel, no capability): every -S name must resolve and every -F pair must be
accepted by audit_rule_fieldpair_data, which is the parser auditctl calls. Prints one line per problem, exits 1 on any."""
import ctypes, ctypes.util, shlex, sys

lib = ctypes.CDLL(ctypes.util.find_library("audit") or "libaudit.so.1")
AUDIT_FILTER_EXIT = 4
lib.audit_rule_create_data  # fail early if the symbol is missing
lib.audit_rule_create_data.restype = ctypes.c_void_p
lib.audit_rule_fieldpair_data.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_int]
lib.audit_name_to_syscall.argtypes = [ctypes.c_char_p, ctypes.c_int]
lib.audit_determine_machine.argtypes = [ctypes.c_char_p]
lib.audit_determine_machine.restype = ctypes.c_int
lib.audit_detect_machine.restype = ctypes.c_int

bad = 0
with open(sys.argv[1]) as fh:
    rules = fh.readlines()
for n, line in enumerate(rules, 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    t = shlex.split(line)
    if t[0] == "-w":
        if "-p" not in t or "-k" not in t:
            print(f"{n}: watch without -p or -k: {line}"); bad += 1
        continue
    if t[0] != "-a":
        print(f"{n}: unexpected rule type: {line}"); bad += 1; continue
    machine = lib.audit_detect_machine()
    rule = ctypes.c_void_p(lib.audit_rule_create_data())
    i = 2
    while i < len(t):
        if t[i] == "-F":
            pair = t[i + 1]
            if pair.startswith("arch="):
                machine = lib.audit_determine_machine(pair[5:].encode())
                if machine < 0:
                    print(f"{n}: unknown arch {pair}"); bad += 1
            rc = lib.audit_rule_fieldpair_data(ctypes.byref(rule), pair.encode(), AUDIT_FILTER_EXIT)
            if rc != 0:
                print(f"{n}: -F {pair} refused by libaudit (rc {rc})"); bad += 1
            i += 2
        elif t[i] == "-S":
            if lib.audit_name_to_syscall(t[i + 1].encode(), machine) < 0:
                print(f"{n}: syscall {t[i + 1]} unknown on this machine"); bad += 1
            i += 2
        elif t[i] == "-k":
            i += 2
        else:
            print(f"{n}: unexpected token {t[i]}"); bad += 1; i += 1
sys.exit(1 if bad else 0)
