#!/usr/bin/env bash
# ==============================================================================
# A journey advertised as unattended must be unattended all the way down.
#
# `cluster-up … APPROVE=auto` gated once, applied phase 1 — fifty billed resources —
# then called bootstrap-phase2 WITHOUT passing APPROVE down. Phase 2 ran a bare
# `tofu apply`, which asks "Do you want to perform these actions?", got EOF and
# died. Three paid deployments found that, one at a time, because no test reads
# the call graph. This one does.
#
# It reads the CALLERS too. cluster-idempotency.sh called `task cluster-up` with
# no approval variable at all, and this harness — which existed for exactly that
# defect — was reading Taskfile.yml and nothing else, so it stayed green while a
# CI stage was guaranteed to stop after a full paid deploy.
#
# Offline: it parses Taskfile.yml, scripts/**/*.sh and .github/workflows/*.yml.
# No cloud, no tofu, no account, no bill.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT

# The call graph is a tree, not something grep can walk: a caller passes APPROVE in
# a `vars:` mapping two levels down from the task that needs it. python3+yaml is
# how the other checks read this file. It prints one verdict per line; the shell
# keeps the counting, so the summary matches every other harness here.
python3 - >"$OUT" <<'PY'
import glob, re, yaml

with open('Taskfile.yml') as fh:
    TASKS = (yaml.safe_load(fh) or {}).get('tasks') or {}

R = []
def hdr(m): R.append(('hdr', m))
def ok(m):  R.append(('ok', m))
def bad(m): R.append(('bad', m))

# The unattended entry point, and the lanes that may not spend money: `local-*`
# is Talos in Docker and `feint-*` is an API emulator on loopback. Neither can
# bill, so they are held to "must not be able to prompt" rather than to the
# cloud lane's plan-then-apply-that-plan contract.
ENTRY = 'cluster-up'
def free_lane(name): return name.startswith(('local-', 'feint-'))

VARREF = re.compile(r'\{\{[^}]*?\.([A-Za-z_][A-Za-z0-9_]*)')

def key(k):
    # PyYAML reads YAML 1.1, where an UNQUOTED `YES:` key is the boolean true.
    # Normalising here measures what go-task sees; the spelling is asserted on
    # its own below.
    return 'YES' if k is True else ('NO' if k is False else str(k))

# ---------------------------------------------------------------------------
# One shell reader for all three inputs. Every blind spot this harness has had
# was a shape it never tokenised: an `echo` chained ahead of a real command, a
# usage message that spans lines, a heredoc, a leading VAR=value. So quotes are
# tracked across lines and the mask below blanks whatever sits inside one.
# ---------------------------------------------------------------------------
HEREDOC = re.compile(r'<<(-?)\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\2')

def scan(line, st):
    """One raw line, carrying the open-construct stack in. Returns
    (text, mask, stack, continued): `text` has any comment removed, and `mask`
    is the same length with every character that lives inside a quote blanked,
    so an operator or a heredoc marker written inside a string is not shell."""
    out, mask, i, n = [], [], 0, len(line)
    while i < n:
        ch, top = line[i], (st[-1] if st else None)
        if top == "'":
            out.append(ch); mask.append('\0')
            if ch == "'": st.pop()
            i += 1; continue
        if ch == '\\' and i + 1 < n:
            out.append(line[i:i+2]); mask.extend('  '); i += 2; continue
        # Per-frame, not stack-wide: a `$(`/`$((` frame is live shell code even
        # nested inside a quoted one, so it must not inherit "blank" from an
        # ancestor `"`/`'` frame — that inheritance is what let `<<` inside
        # `"$(...)"` read as quoted text and skip the heredoc-skip path.
        blank = top in ('"', "'")
        if top == '"' and not line.startswith('$(', i):
            out.append(ch); mask.append('\0')
            if ch == '"': st.pop()
            i += 1; continue
        for opener, closer in (('$((', '))'), ('$(', ')')):
            if line.startswith(opener, i):
                st.append(opener); out.append(opener)
                mask.extend('\0' * len(opener) if blank or top == '"' else ' ' * len(opener))
                i += len(opener); break
        else:
            if top in ('$((', '$(') and line.startswith({'$((': '))', '$(': ')'}[top], i):
                c = {'$((': '))', '$(': ')'}[top]
                st.pop(); out.append(c); mask.extend(('\0' if blank else ' ') * len(c))
                i += len(c); continue
            if ch in '"\'':
                st.append(ch); out.append(ch); mask.append('\0'); i += 1; continue
            if ch == '#' and not st and (i == 0 or line[i-1].isspace()):
                break
            out.append(ch); mask.append('\0' if blank else ch); i += 1
    text = ''.join(out)
    return text, ''.join(mask), st, (not st and text.rstrip().endswith('\\'))

def logical_lines(text):
    """(lineno, line, mask) as the shell would see them: continuations AND
    multi-line strings joined, whole-line comments and heredoc bodies dropped.
    Raises rather than returning a short list — a reader that silently swallows
    the rest of a file is a check that reports 'nothing wrong'."""
    raw, out = text.splitlines(), []
    i, st, buf, mbuf, start = 0, [], '', '', 0
    while i < len(raw):
        line = raw[i]
        if not st and not buf and line.lstrip().startswith('#'):
            i += 1; continue
        if not buf:
            start = i + 1
        t, m, st, cont = scan(line, st)
        i += 1
        # A heredoc's body is consumed right after ITS OWN line, exactly as
        # bash reads it — regardless of any $(...) / "..." still open around
        # it. Checked per raw line, not the accumulated buffer: deferring this
        # to where the whole logical line closes let a body embedded inside a
        # still-open construct be scanned as shell instead of skipped, and its
        # own quotes/parens then corrupted the stack this function tracks.
        for h in (HEREDOC.match(t, p.start()) for p in re.finditer('<<', m)):
            if not h:
                continue
            delim, dash = h.group(3), h.group(1) == '-'
            while i < len(raw):
                cur = raw[i]; i += 1
                if (cur.strip() if dash else cur.rstrip()) == delim:
                    break
        if cont:
            buf += t.rstrip()[:-1] + ' '; mbuf += m.rstrip()[:-1] + ' '; continue
        buf += t; mbuf += m
        if st:                       # still inside a string: it keeps reading
            buf += ' '; mbuf += ' '; continue
        out.append((start, buf, mbuf))
        buf, mbuf = '', ''
    if st:
        raise ValueError('unterminated ' + ''.join(st))
    return out

SPLIT = re.compile(r'&&|\|\||[;|]')
REDIR = re.compile(r'^\d*(?:>>|>|<|>&|<&)')
ASSIGN = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', re.S)
LEAD = {'if', 'then', 'elif', 'else', 'do', 'while', 'until', 'time', 'exec', 'sudo', 'command', '!'}

def segments(line, mask):
    """Command segments — split only on operators the mask says are unquoted."""
    parts, last = [], 0
    for m in SPLIT.finditer(mask):
        parts.append(line[last:m.start()]); last = m.end()
    parts.append(line[last:])
    return [p.strip() for p in parts if p.strip()]

def tokens(seg):
    out, cur, q = [], '', None
    for ch in seg:
        if q:
            cur += ch
            if ch == q: q = None
        elif ch in '"\'':
            q = ch; cur += ch
        elif ch.isspace():
            if cur: out.append(cur); cur = ''
        else:
            cur += ch
    if cur: out.append(cur)
    return out

def trim(t):
    t = t.lstrip('(!{ ')
    while t.endswith((')', '}')) and t.count(')') + t.count('}') > t.count('(') + t.count('{'):
        t = t[:-1]
    return t

def lead(tk):
    """Index of the real command word: leading keywords, subshell parens and
    VAR=value assignments skipped. `TF_LOG=info tofu apply …` is still an apply,
    and `APPROVE=auto task cluster-up` still passes the knob (VERIFIED on Task
    3.52: go-task reads its variables from the environment too)."""
    i = 0
    while i < len(tk):
        t = trim(tk[i])
        if t and t not in LEAD and not ASSIGN.match(t):
            break
        i += 1
    return i

def command(seg):
    """(env-prefix, argv) of a segment."""
    tk = tokens(seg)
    i = lead(tk)
    env = {}
    for t in tk[:i]:
        m = ASSIGN.match(trim(t))
        if m:
            env[m.group(1)] = m.group(2)
    return env, [trim(x) for x in tk[i:]]

# go-task flags with a separate value token (VERIFIED on Task 3.52 --help):
# `task -d somedir cluster-up` has the callee at index 2, not 1 — skipping
# `-d` alone reads `somedir` as the callee and misses the real one entirely.
TASK_TAKES_VALUE = {'-d', '--dir', '-t', '--taskfile', '-o', '--output',
                     '--output-group-begin', '--output-group-end'}

def task_call(seg):
    """(callee, vars) if this segment runs `task`, else None."""
    env, argv = command(seg)
    if not argv or argv[0] != 'task':
        return None
    rest = argv[1:]
    if '--' in rest:
        rest = rest[:rest.index('--')]   # past `--` it is CLI_ARGS, not a task var
    callee, kv, skip = None, dict(env), False
    for t in rest:
        if skip:
            skip = False; continue
        if t.startswith('-'):
            name = t.split('=', 1)[0]
            skip = name in TASK_TAKES_VALUE and '=' not in t
            continue
        if REDIR.match(t):
            continue
        m = ASSIGN.match(t)
        if m:
            kv[m.group(1)] = m.group(2)
        elif callee is None:
            callee = t
    return (ALIAS.get(callee, callee), kv) if callee else None

def shell_calls(text):
    """(lineno, callee, vars) for every `task …` a shell text really runs."""
    for ln, line, mask in logical_lines(text):
        for seg in segments(line, mask):
            c = task_call(seg)
            if c:
                # The raw segment travels with the call: everything after `--`
                # is invisible to the parsed vars, and an invocation's flags are
                # what say whether it can reach an approval at all.
                yield (ln,) + c + (seg,)

def unquote(v):
    v = v.strip()
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] and v[0] in '"\'' else v

DEFAULTED = re.compile(r'^\$\{[A-Za-z_][A-Za-z0-9_]*:[-=](.*)\}$')

def approves(v):
    """Does this value provably reach go-task as `auto`? VERIFIED on Task 3.52:
    an EMPTY value is not a value — `{{.APPROVE | default "ask"}}` wins — so
    present-but-empty is exactly as bad as absent, and a bare `$VAR` may be
    either. Only a literal, or an expansion that defaults to one, is provable."""
    v = unquote(v)
    if v == 'auto':
        return True
    m = DEFAULTED.match(v)
    return bool(m and unquote(m.group(1)) == 'auto')

# --- what each task is ------------------------------------------------------
def blocks(t):
    """Every shell command string of a task, in order."""
    out = []
    for c in (t.get('cmds') or []):
        if isinstance(c, str):
            out.append(c)
        elif isinstance(c, dict):
            for k in ('cmd', 'defer'):
                if isinstance(c.get(k), str):
                    out.append(c[k])
    return out

BODY = {n: "\n".join(blocks(t)) for n, t in TASKS.items() if isinstance(t, dict)}
ALIAS = {}
for n, t in TASKS.items():
    ALIAS[n] = n
    for a in ((t.get('aliases') or []) if isinstance(t, dict) else []):
        ALIAS[str(a)] = n

def alternatives(name):
    """Vars other than APPROVE that the callee's own gate accepts instead. Read from
    the gate itself: infra-apply refuses unless PLAN or APPROVE is given, so a caller
    handing it a plan file it has already read is not forgetting anything."""
    alts = set()
    for line in BODY[name].splitlines():
        s = line.strip()
        if re.match(r'(if|elif)\b', s) and re.search(r'\{\{[^}]*\.APPROVE', s):
            alts |= {v for v in VARREF.findall(s) if v != 'APPROVE'}
    return alts

def callers():
    """(caller, callee, how, vars) for all three call forms — the `- task:` list
    entry, a `deps:` entry, and a `task <name> VAR=…` line in a shell block. A
    call form nobody reads is where the next one of these will hide."""
    for name, t in TASKS.items():
        if not isinstance(t, dict):
            continue
        for how, entries in (('task:', t.get('cmds') or []), ('deps', t.get('deps') or [])):
            for c in entries:
                if isinstance(c, str):
                    if how == 'deps':
                        yield name, ALIAS.get(c, c), how, {}
                elif c.get('task'):
                    yield name, ALIAS.get(c['task'], c['task']), how, {key(k): str(v) for k, v in (c.get('vars') or {}).items()}
        for _, callee, kv, _seg in shell_calls(BODY[name]):
            yield name, callee, 'shell', kv

EDGES = list(callers())

# A task NEEDS the approval when its own body reads it, or when it forwards it to
# one that does: a pure wrapper has no `{{.APPROVE}}` of its own and would
# otherwise look exempt to every caller of it.
NEEDS = {n for n, b in BODY.items() if 'APPROVE' in VARREF.findall(b)}
while True:
    grown = {c for c, e, _, kv in EDGES
             if e in NEEDS and c != e and not (alternatives(e) & set(kv))} - NEEDS
    if not grown:
        break
    NEEDS |= grown

# `tofu [-chdir=…] apply …` — flags with a separate value must not be mistaken
# for the plan file, which is the whole distinction being measured.
APPLY = re.compile(r'^tofu\b((?:\s+-\S+)*)\s+apply\b(.*)$')
TAKES_VALUE = {'-var', '-var-file', '-target', '-replace', '-state', '-parallelism', '-lock-timeout'}

def classify(args):
    """A redirection is the shell's, not the apply's: `2>&1` was counted as a
    second positional once, and called a saved plan piped into tee interactive."""
    positional, flags, skip, drop = [], set(), False, False
    for tok in tokens(args):
        if drop:
            drop = False; continue
        m = REDIR.match(tok)
        if m:
            drop = tok == m.group(0)   # a bare `>` / `2>` / `<`: its target is next
            continue
        if skip:
            skip = False; continue
        if tok.startswith('-'):
            name = tok.split('=', 1)[0]
            flags.add(name)
            skip = name in TAKES_VALUE and '=' not in tok
        else:
            positional.append(tok)
    if '-auto-approve' in flags:
        return 'auto-approve'
    if len(positional) == 1 and not ({'-var', '-var-file'} & flags):
        return 'saved-plan'
    return 'prompting'

def applies():
    for name in BODY:
        for _, line, mask in logical_lines(BODY[name]):
            for seg in segments(line, mask):
                tk = tokens(seg)
                m = APPLY.match(' '.join(tk[lead(tk):]))
                if m:
                    yield name, seg, classify(m.group(2))

# --- A. the defect itself: APPROVE must survive every call edge -----------------
hdr('APPROVE reaches every task whose body reads it')
edges = 0
for caller, callee, how, kv in EDGES:
    if callee not in NEEDS or caller == callee:
        continue
    edges += 1
    alts = alternatives(callee)
    given = kv.get('APPROVE')
    if given is not None and (('.APPROVE' in given) or approves(given)):
        ok(f'{caller} → {callee} ({how}) carries APPROVE')
    elif given is not None:
        bad(f'{caller} → {callee} ({how}) passes APPROVE={given!r} — it hard-codes an answer instead of forwarding the operator\'s')
    elif alts & {k for k, v in kv.items() if unquote(v)}:
        ok(f'{caller} → {callee} ({how}) gives {sorted(alts & set(kv))[0]}, which {callee}\'s own gate accepts instead of APPROVE')
    else:
        want = ' or '.join(sorted(alts | {'APPROVE'}))
        bad(f'{caller} → {callee} ({how}) passes no {want} — {callee} stops for an approval nobody can answer, AFTER {caller} has already spent')

# --- B. how an apply is allowed to ask ---------------------------------------
hdr('every apply is a saved plan (cloud) or at least cannot prompt (free lanes)')
seen = {'cloud': 0, 'free': 0}
for name, seg, kind in applies():
    lane = 'free' if free_lane(name) else 'cloud'
    seen[lane] += 1
    short = re.sub(r'\s+', ' ', seg)[:70]
    if lane == 'cloud':
        if kind == 'saved-plan':
            ok(f'{name}: applies a saved plan — `{short}`')
        elif kind == 'auto-approve':
            bad(f'{name}: -auto-approve — nothing is frozen between the reading and the doing: `{short}`')
        else:
            bad(f'{name}: this apply asks "Do you want to perform these actions?" and dies on EOF unattended: `{short}`')
    else:
        if kind == 'prompting':
            bad(f'{name}: free lane, but this apply can still prompt: `{short}`')
        else:
            ok(f'{name}: free lane, and this apply cannot prompt ({kind})')

# --- C. a prompt must be skippable AND never attempted in the dark -----------
hdr('every question is guarded by APPROVE and by a terminal test')
prompts = 0
for name in BODY:
    if free_lane(name):
        continue
    for b in blocks(TASKS[name]):
        if not re.search(r'^\s*read\s+(-r\b|[A-Za-z_])', b, re.M):
            continue
        # A question is only this guard's business when it gates something that
        # SPENDS. Asked of every `read`, it reddened on a plain helper that
        # prompts for a value and runs nothing — the exact shape this repo has
        # been burned by three times: a guard that fails on correct work gets
        # muted, and then it protects nothing.
        if not re.search(r'\btofu\b', b) and not re.search(r'^\s*task\s+[a-z]', b, re.M):
            ok(f'{name} prompts, but that block spends nothing — not this guard\'s business')
            continue
        prompts += 1
        missing = [w for w, p in (('APPROVE', r'\{\{[^}]*\.APPROVE'), ('a terminal test ([ -t 0 ])', r'-t 0')) if not re.search(p, b)]
        if missing:
            bad(f'{name} prompts without {" and without ".join(missing)} — unattended it hangs or EOFs')
        else:
            ok(f'{name} prompts only with a terminal and without APPROVE')

# --- D. the var has to survive being read back -------------------------------
hdr('no task var is spelled as a YAML 1.1 boolean')
bools = []
for name, t in TASKS.items():
    if not isinstance(t, dict):
        continue
    for k in (t.get('vars') or {}):
        if isinstance(k, bool):
            bools.append(f'{name} vars')
    for c in (t.get('cmds') or []):
        if isinstance(c, dict):
            for k in (c.get('vars') or {}):
                if isinstance(k, bool):
                    bools.append(f'{name} → {c.get("task")} vars')
if bools:
    for b in sorted(set(bools)):
        bad(f'{b}: an unquoted YES/NO key. Any YAML 1.1 reader — this check included — sees `true`, not YES, and stops seeing the variable at all')
else:
    ok('no unquoted YES/NO key: a 1.1 reader and go-task agree on what the vars are called')

# --- E. the same forgotten-flag defect, one lane over ------------------------
# talos-image.sh has two applies: --ensure applies a saved plan (never prompts),
# the plain path prompts. So the unattended entry must carry ENSURE.
hdr('the image build the entry point triggers is the non-interactive one')
img = [(callee, kv) for c, callee, _, kv in EDGES if c == ENTRY and callee == 'image-build']
if not img:
    bad(f'{ENTRY} no longer calls image-build — this check is measuring a journey that moved')
def ensures(v):
    """Does this value provably make image-build take --ensure? A literal
    truthy string does; an unresolved {{ }} template token does not — reaching
    here unresolved means the var was forwarded, not given, and forwarding
    proves nothing about what cluster-up's own caller actually passed."""
    v = unquote(v)
    return bool(v) and '{{' not in v

for callee, kv in img:
    if ensures(kv.get('ENSURE', '')):
        ok(f'{ENTRY} → image-build carries ENSURE={kv["ENSURE"]}')
    else:
        bad(f'{ENTRY} → image-build passes no ENSURE — talos-image.sh then takes its prompt-capable apply')
    if '--ensure' in BODY.get('image-build', ''):
        ok('image-build forwards it to talos-image.sh as --ensure')
    else:
        bad('image-build does not forward --ensure — the ENSURE var is inert')

# --- F. the callers OUTSIDE the Taskfile -------------------------------------
# THE RULE. Anything that runs `task <something that needs the approval>` must
# hand it one. The single exemption is a script that REFUSES to run without a
# terminal: the exemption is a behaviour, not a label, so claiming it costs the
# author the same headless run they were trying to stay silent about. A CI step
# has no terminal by construction and is never exempt.
SCRIPTS = sorted(glob.glob('scripts/**/*.sh', recursive=True))
WORKFLOWS = sorted(glob.glob('.github/workflows/*.yml') + glob.glob('.github/workflows/*.yaml'))

TTY = re.compile(r'(\[\[?|\btest\b)[^;]*?-t\s+[01]')

def refuses_headless(lines):
    """True when the script cannot run without a terminal: a tty test that exits,
    on its own statement, gating a while/until loop, or — for an `if` — in the
    branch actually taken when the test FAILS (no tty), not just anywhere in
    the if/else. An exit in the branch taken when a tty IS present proves
    nothing: the script still runs on to prompt in the headless case."""
    for n, (_, line, _) in enumerate(lines):
        if not TTY.search(line):
            continue
        if re.search(r'\bexit\b', line):
            return True
        head = line.strip()
        if re.match(r'(while|until)\b', head):
            depth = 0
            for _, nxt, nmask in lines[n:]:
                for seg in segments(nxt, nmask):
                    if re.match(r'(if|while|until)\b', seg): depth += 1
                    if seg.strip() in ('fi', 'done'): depth -= 1
                if re.search(r'\bexit\b', nxt):
                    return True
                if depth <= 0 and n:
                    break
            continue
        if not re.match(r'if\b', head):
            continue
        # The branch reached when the test fails is `else` — unless the test
        # itself is negated (`! [ -t 0 ]` / `[ ! -t 0 ]`), in which case it is
        # `then`: a bare position match, not full boolean parsing, but enough
        # to tell the two idioms actually used here apart.
        bang, tty_at = head.find('!'), TTY.search(head).start()
        no_tty_branch = 'then' if 0 <= bang < tty_at else 'else'
        depth, branch, hit = 0, 'then', {'then': False, 'else': False}
        for _, nxt, nmask in lines[n:]:
            for seg in segments(nxt, nmask):
                if re.match(r'if\b', seg):
                    depth += 1; continue
                if seg == 'fi':
                    depth -= 1; continue
                if depth != 1:
                    continue    # nested if/fi: not this branch's own exit
                if seg == 'else':
                    branch = 'else'; continue
                if re.match(r'elif\b', seg):
                    branch = None; continue   # a different condition entirely
                if branch and re.search(r'\bexit\b', seg):
                    hit[branch] = True
            if depth <= 0:
                break
        if hit[no_tty_branch]:
            return True
    return False

def call_sites():
    """(kind, file, line, callee, vars, exempt_ok) for every `task …` outside
    the Taskfile. `exempt_ok` is False for a workflow step: there is no tty in
    a runner, so no CI caller can ever claim the interactive exemption."""
    for f in SCRIPTS:
        with open(f) as fh:
            text = fh.read()
        try:
            lines = logical_lines(text)
        except ValueError as e:
            bad(f'{f}: could not be read as shell ({e}) — it was NOT checked')
            continue
        interactive = refuses_headless(lines)
        for ln, line, mask in lines:
            for seg in segments(line, mask):
                c = task_call(seg)
                if c:
                    yield 'script', f, ln, c[0], c[1], interactive, seg
    for f in WORKFLOWS:
        with open(f) as fh:
            raw = fh.read()
        doc = yaml.safe_load(raw) or {}
        top = {str(k): str(v) for k, v in (doc.get('env') or {}).items()}
        for job in (doc.get('jobs') or {}).values():
            if not isinstance(job, dict):
                continue
            jenv = dict(top, **{str(k): str(v) for k, v in (job.get('env') or {}).items()})
            for step in (job.get('steps') or []):
                run = step.get('run') if isinstance(step, dict) else None
                if not isinstance(run, str):
                    continue
                senv = dict(jenv, **{str(k): str(v) for k, v in (step.get('env') or {}).items()})
                for ln, callee, kv, seg in shell_calls(run):
                    # The run: block's own numbering restarts at 1; point at the
                    # real file line so the message is actionable.
                    body = run.splitlines()[ln - 1].strip() if ln <= len(run.splitlines()) else ''
                    at = next((i + 1 for i, s in enumerate(raw.splitlines()) if body and body in s), 0)
                    yield 'workflow', f, at, callee, dict(senv, **kv), False, seg

hdr('every task invocation in scripts/ and .github/workflows/ carries the approval')
sites = list(call_sites())
external = 0
claimed = {}
for kind, f, ln, callee, kv, interactive, seg in sites:
    if callee not in NEEDS:
        continue
    external += 1
    alts = alternatives(callee)
    given = kv.get('APPROVE')
    where = f'{f}:{ln}'
    if given is not None and approves(given):
        ok(f'{where} runs `task {callee}` with APPROVE={unquote(given)}')
    elif alts & {k for k, v in kv.items() if unquote(v)}:
        ok(f'{where} runs `task {callee}` with {sorted(alts & set(kv))[0]}, which its gate accepts instead of APPROVE')
    # An invocation that cannot REACH the approval does not need to answer it.
    # cluster-down's gate lives in fleet-down.sh: with no plan file it computes
    # one and destroys nothing, and that half must stay answerable by nobody.
    # Demanding APPROVE=auto there would be a guard right for the wrong reason,
    # and would push CI to assert an authority the step does not need.
    elif callee == 'cluster-down' and not unquote(kv.get('PLAN', '')) and '--plan-file' not in seg:
        ok(f'{where} runs `task {callee}` to plan only — it lands nothing, so there is no approval to answer')
    elif interactive:
        claimed[f] = True
        ok(f'{where} runs `task {callee}` with no APPROVE, but {f} refuses to run without a terminal — a human is there to answer')
    else:
        why = ('a workflow `run:` has no tty, ever' if kind == 'workflow'
               else f'{f} does not refuse to run without a terminal')
        detail = (f'APPROVE={given!r}, which go-task drops — an empty value loses to `default "ask"`'
                  if given is not None else f'no {" or ".join(sorted(alts | {"APPROVE"}))}')
        bad(f'{where} runs `task {callee}` with {detail}. {why}, so {callee} stops at its approval — after whatever ran before it has already spent')

# The exemption must stay expensive. A script that refuses without a terminal
# cannot also be a CI step: that job would die at second zero.
def reaches_script(name, script, seen=None):
    """True when task `name` shells out to `script`, directly or by calling
    (via any Taskfile edge) a task that does. CI reaching the script through a
    wrapper task is still CI reaching it — the literal-path search below only
    sees a workflow that names the script itself."""
    seen = seen if seen is not None else set()
    if name in seen:
        return False
    seen.add(name)
    if script in BODY.get(name, ''):
        return True
    return any(reaches_script(callee, script, seen)
               for caller, callee, _, _ in EDGES if caller == name)

for f in sorted(claimed):
    used = [w for w in WORKFLOWS if re.search(re.escape(f), open(w).read())]
    if not used:
        wrappers = {n for n in TASKS if reaches_script(n, f)}
        used = sorted({s[1] for s in sites if s[0] == 'workflow' and s[3] in wrappers})
        via = ' (via a task wrapper)' if used else ''
    else:
        via = ''
    if used:
        bad(f'{f} claims the interactive exemption yet {used[0]} runs it as a CI step{via} — it would refuse at second zero')
    else:
        ok(f'{f} claims the interactive exemption and no workflow runs it')

# --- G. floors: a check that measured nothing is not a green run -------------
# This is the fix for the defect that started this: the harness read Taskfile.yml
# and nothing else, so a tree containing only that file still printed a green
# summary. Zero of anything below means the parser went blind, not that the
# repository is clean.
hdr('the analysis actually found something to measure')
# Baseline is what this repo actually measured, not "non-zero": non-zero let a
# real count of 8 drop to 1 and stay green, which is the defect this floor
# exists to catch. Bump a number here deliberately when the repo's shape
# genuinely changes (a task removed, a script deleted) — never to silence a
# failure without checking why the count moved first.
FLOORS = {'tasks that need APPROVE': 5, 'call edges into them': 2,
          'cloud-lane applies': 4, 'guarded prompts': 2,
          'shell scripts read': 77, 'workflow files read': 3,
          '`task …` invocations found outside the Taskfile': 32,
          'of them into a task that needs APPROVE': 8}
for label, n in (('tasks that need APPROVE', len(NEEDS)), ('call edges into them', edges),
                 ('cloud-lane applies', seen['cloud']), ('guarded prompts', prompts),
                 ('shell scripts read', len(SCRIPTS)), ('workflow files read', len(WORKFLOWS)),
                 ('`task …` invocations found outside the Taskfile', len(sites)),
                 ('of them into a task that needs APPROVE', external)):
    floor = FLOORS[label]
    if n >= floor:
        ok(f'{n} {label}')
    else:
        bad(f'{n} {label} — below the floor of {floor}: the parser is broken, the journey was renamed under it, or a real drop needs a deliberate bump here')

print("\n".join(f'{v}|{m}' for v, m in R))
PY
RC=$?
[ "$RC" -eq 0 ] || { echo "✗ the sources could not be parsed (exit $RC) — nothing was checked" >&2; exit 1; }

while IFS='|' read -r verdict msg; do
  case "$verdict" in
    hdr) printf -- '--- %s ---\n' "$msg" ;;
    ok)  ok "$msg" ;;
    bad) bad "$msg" ;;
  esac
done <"$OUT"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
