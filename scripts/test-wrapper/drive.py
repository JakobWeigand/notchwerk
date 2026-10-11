import json, os, shutil, signal, subprocess, sys, time, threading

# Aufruf über run.sh: WRAP_BIN enthält die aus der App-Quelle geschriebenen Skripte, WRAP_TMP ist ein leerer
# Arbeitsordner. Jeder Fall bekommt ein eigenes HOME darin und berührt nie dein echtes ~/.claude-notch.
HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ["WRAP_BIN"]
TMP = os.environ["WRAP_TMP"]
WRAPPER_SH = os.path.join(BIN, "claude-wrapper")
WRAPPER_PY = os.path.join(BIN, "claude-wrapper.py")
FAKE = os.path.join(HERE, "fake_claude.py")
results = []

def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  -> " + detail))

def fresh_home(tag):
    home = os.path.join(TMP, "home-" + tag)
    shutil.rmtree(home, ignore_errors=True)
    os.makedirs(os.path.join(home, ".claude-notch"))
    return home

def user(text):
    return json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}, "parent_tool_use_id": None}) + "\n"
INIT = json.dumps({"type": "control_request", "request_id": "req_1", "request": {"subtype": "initialize", "hooks": {}}}) + "\n"
SETMODEL = json.dumps({"type": "control_request", "request_id": "req_2", "request": {"subtype": "set_model", "model": "sonnet"}}) + "\n"
INTERRUPT = json.dumps({"type": "control_request", "request_id": "req_9", "request": {"subtype": "interrupt"}}) + "\n"

def run(home, env_extra, steps, via_sh=True, python=None, args=("--input-format", "stream-json", "--output-format", "stream-json", "--resume", "bbbbbbbb-0000-4000-8000-000000000002") , wait_results=None):
    """steps: Liste von Zeilen oder ('wait', n) / ('call', fn). Gibt (stdout-Zeilen, Fake-Log, returncode) zurück."""
    env = dict(os.environ)
    env.pop("CLAUDE_CONFIG_DIR", None)
    env.update({"HOME": home, "FAKE_LOG": os.path.join(home, "fake.log")})
    env.update(env_extra)
    cmd = ["sh", WRAPPER_SH, FAKE] if via_sh else [python or "/usr/bin/python3", WRAPPER_PY, FAKE]
    p = subprocess.Popen(cmd + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    out, got = [], threading.Event()
    def reader():
        for line in iter(p.stdout.readline, b""):
            out.append(json.loads(line))
    t = threading.Thread(target=reader, daemon=True); t.start()
    def results_seen(): return sum(1 for o in out if o.get("type") == "result")
    for step in steps:
        if isinstance(step, tuple):
            if step[0] == "wait":
                deadline = time.time() + 15
                while results_seen() < step[1] and time.time() < deadline and p.poll() is None: time.sleep(0.05)
            elif step[0] == "call": step[1]()
            elif step[0] == "signal": p.send_signal(step[1])
        else:
            p.stdin.write(step.encode()); p.stdin.flush()
    if not any(isinstance(s, tuple) and s[0] == "signal" for s in steps):
        try: p.stdin.close()
        except Exception: pass
    try: rc = p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill(); rc = "TIMEOUT"
    t.join(timeout=3)
    log = []
    lp = os.path.join(home, "fake.log")
    if os.path.exists(lp): log = [json.loads(l) for l in open(lp)]
    return out, log, rc, p.stderr.read().decode()

def types(out): return [(o.get("type"), o.get("subtype")) for o in out]
def results_text(out): return [o.get("result") for o in out if o.get("type") == "result"]
def starts(log): return [l for l in log if l["event"] == "start"]
WORK = lambda home: os.path.join(home, ".claude-work")
def write_limits(home, blocked):
    with open(os.path.join(home, ".claude-notch", "limits.json"), "w") as f:
        json.dump({"version": 1, "updatedAt": int(time.time()), "accounts": {k: {"blockedUntil": int(time.time()) + v} for k, v in blocked.items()}}, f)

SEAMLESS = lambda home: {"NOTCHWERK_FALLBACK_CONFIG_DIR": WORK(home), "NOTCHWERK_SEAMLESS": "1"}

# T1: ohne Limit alles unverändert durchgereicht
home = fresh_home("t1")
out, log, rc, err = run(home, SEAMLESS(home), [INIT, user("hallo"), ("wait", 1)])
check("T1 ohne Limit: Antwort kommt unverändert", results_text(out) == ["Antwort von default auf: hallo"], str(results_text(out)))
check("T1 nur ein claude gestartet, mit dem Hauptkonto", len(starts(log)) == 1 and starts(log)[0]["cfg"] == "default", str(starts(log)))
check("T1 Exit-Code 0 nach Ende der Eingabe", rc == 0, str(rc))

# T2: Limit bei der ersten Nachricht, kein Protokoll vorhanden → neue Sitzung mit gleicher ID
home = fresh_home("t2")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default"), [INIT, SETMODEL, user("frage eins"), ("wait", 1)],
                        args=("--input-format", "stream-json"))
t = types(out)
check("T2 Editor sieht keine Limit-Meldung", ("rate_limit_event", None) not in t and not any(o.get("message", {}).get("model") == "<synthetic>" for o in out if o.get("type") == "assistant"), str(t))
check("T2 Editor sieht genau eine erfolgreiche Antwort des Ausweichkontos", results_text(out) == ["Antwort von %s auf: frage eins" % WORK(home)], str(results_text(out)))
check("T2 keine Fehler-Ergebnisse", not any(o.get("is_error") for o in out if o.get("type") == "result"))
s = starts(log)
check("T2 zwei Starts: erst Hauptkonto, dann Ausweichkonto", [x["cfg"] for x in s] == ["default", WORK(home)], str([x["cfg"] for x in s]))
check("T2 Ausweichkonto mit --session-id (gleiche ID wie im Editor)", "--session-id" in s[1]["args"] and "aaaaaaaa-0000-4000-8000-000000000001" in s[1]["args"], str(s[1]["args"]))
w = [l for l in log if l["cfg"] == WORK(home) and l["event"] == "stdin"]
check("T2 Start-Anfragen (initialize, set_model) wiederholt, mit neuer Kennung", [x["sub"] for x in w if x["type"] == "control_request"] == ["initialize", "set_model"], str(w))
check("T2 gescheiterte Nachricht wiederholt", [x["text"] for x in w if x["type"] == "user"] == ["frage eins"], str(w))
inits = [o for o in out if o.get("type") == "system" and o.get("subtype") == "init"]
check("T2 zweite init-Meldung wird nicht an den Editor weitergegeben", len(inits) == 1, str(len(inits)))
check("T2 Antworten auf die wiederholten Anfragen erreichen den Editor nicht", len([o for o in out if o.get("type") == "control_response"]) == 2, str([o for o in out if o.get("type") == "control_response"]))

# T3: Limit bei der zweiten Nachricht, Protokoll vorhanden → --resume und Protokoll kopiert
home = fresh_home("t3")
flag = os.path.join(home, "limit-now")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default", FAKE_LIMIT_FILE=flag),
                        [INIT, user("eins"), ("wait", 1), ("call", lambda: open(flag, "w").close()), user("zwei"), ("wait", 2)],
                        args=("--input-format", "stream-json"))
check("T3 beide Antworten, die zweite vom Ausweichkonto", results_text(out) == ["Antwort von default auf: eins", "Antwort von %s auf: zwei" % WORK(home)], str(results_text(out)))
s = starts(log)
check("T3 Ausweichkonto mit --resume", len(s) == 2 and "--resume" in s[1]["args"], str(s))
copied = os.path.join(WORK(home), "projects", "-test-project", "aaaaaaaa-0000-4000-8000-000000000001.jsonl")
check("T3 Protokoll zum Ausweichkonto kopiert, nur für mich lesbar", os.path.isfile(copied) and (os.stat(copied).st_mode & 0o777) == 0o600, "fehlt oder Rechte falsch")

# T4: Limit mitten in der Antwort → Fortsetzen statt Wiederholen
home = fresh_home("t4")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default", FAKE_MIDTURN="1"), [INIT, user("lange aufgabe"), ("wait", 1)], args=("--input-format", "stream-json"))
w = [l for l in log if l["cfg"] == WORK(home) and l["event"] == "stdin" and l["type"] == "user"]
check("T4 neues Konto bekommt 'weitermachen' statt der Originalnachricht", len(w) == 1 and "continue exactly where you left off" in w[0]["text"], str(w))
check("T4 Editor sieht erst die Teilantwort, dann die fertige", results_text(out) == ["Antwort von %s auf: %s" % (WORK(home), w[0]["text"])] if w else False, str(results_text(out)))

# T5: beide am Limit → eine Umleitung, dann Meldung durchreichen (kein Hin und Her)
home = fresh_home("t5")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default,%s" % WORK(home)), [INIT, user("x"), ("wait", 1)], args=("--input-format", "stream-json"))
check("T5 nur ein Wechsel, kein Hin und Her", len(starts(log)) == 2, str([x["cfg"] for x in starts(log)]))
check("T5 Limit-Meldung des zweiten Kontos erreicht den Editor", any(o.get("is_error") for o in out if o.get("type") == "result"), str(results_text(out)))

# T6: Ausweichkonto laut Notchwerk gesperrt → nicht wechseln
home = fresh_home("t6")
write_limits(home, {WORK(home): 3600})
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default"), [INIT, user("x"), ("wait", 1)], args=("--input-format", "stream-json"))
check("T6 kein Wechsel zu einem gesperrten Konto", len(starts(log)) == 1 and any(o.get("is_error") for o in out if o.get("type") == "result"), str([x["cfg"] for x in starts(log)]))

# T7: Hauptkonto beim Start laut Notchwerk gesperrt → gleich mit dem Ausweichkonto starten (mit und ohne Proxy)
for seamless in ("1", "0"):
    home = fresh_home("t7" + seamless)
    write_limits(home, {"default": 3600})
    env = {"NOTCHWERK_FALLBACK_CONFIG_DIR": WORK(home), "NOTCHWERK_SEAMLESS": seamless}
    # Protokoll der Sitzung liegt nur beim Hauptkonto
    d = os.path.join(home, ".claude", "projects", "-test-project"); os.makedirs(d)
    open(os.path.join(d, "bbbbbbbb-0000-4000-8000-000000000002.jsonl"), "w").write('{"type":"user"}\n')
    out, log, rc, err = run(home, env, [INIT, user("hallo"), ("wait", 1)])
    check("T7 (seamless=%s) Start gleich beim Ausweichkonto" % seamless, [x["cfg"] for x in starts(log)] == [WORK(home)], str([x["cfg"] for x in starts(log)]))
    check("T7 (seamless=%s) Protokoll der fortgesetzten Sitzung vorher kopiert" % seamless,
          os.path.isfile(os.path.join(WORK(home), "projects", "-test-project", "bbbbbbbb-0000-4000-8000-000000000002.jsonl")))

# T8: ohne Ausweichkonto: claude wird unverändert gestartet
home = fresh_home("t8")
out, log, rc, err = run(home, {}, [INIT, user("hallo"), ("wait", 1)])
check("T8 ohne Ausweichkonto: unverändert, Hauptkonto", results_text(out) == ["Antwort von default auf: hallo"] and [x["cfg"] for x in starts(log)] == ["default"], str(results_text(out)))

# T9: Hauptkonto ist ein weiteres Konto (CLAUDE_CONFIG_DIR gesetzt), Ausweichkonto = Standardkonto ("default")
home = fresh_home("t9")
env = {"CLAUDE_CONFIG_DIR": WORK(home), "NOTCHWERK_FALLBACK_CONFIG_DIR": "default", "NOTCHWERK_SEAMLESS": "1", "FAKE_LIMITED": WORK(home)}
out, log, rc, err = run(home, env, [INIT, user("x"), ("wait", 1)], args=("--input-format", "stream-json"))
check("T9 Wechsel vom weiteren Konto zum Standardkonto: Variable beim Standardkonto ungesetzt", [x["cfg"] for x in starts(log)] == [WORK(home), "default"], str([x["cfg"] for x in starts(log)]))

# T10: SIGTERM wird weitergegeben, Exit-Code 143
home = fresh_home("t10")
out, log, rc, err = run(home, SEAMLESS(home), [INIT, user("x"), ("wait", 1), ("signal", signal.SIGTERM)])
check("T10 SIGTERM beendet Wrapper (143)", rc == 143, str(rc))

# T11: derselbe Test mit dem Python von macOS (3.9) statt Homebrew
home = fresh_home("t11")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default"), [INIT, user("x"), ("wait", 1)], via_sh=False, python="/usr/bin/python3", args=("--input-format", "stream-json"))
check("T11 Python 3.9: Wechsel funktioniert", results_text(out) == ["Antwort von %s auf: x" % WORK(home)], str(results_text(out)) + err[-300:])

# T12: Interrupt wird durchgereicht, aber nicht wiederholt
home = fresh_home("t12")
out, log, rc, err = run(home, dict(SEAMLESS(home), FAKE_LIMITED="default"), [INIT, INTERRUPT, user("x"), ("wait", 1)], args=("--input-format", "stream-json"))
w = [l for l in log if l["cfg"] == WORK(home) and l["event"] == "stdin" and l["type"] == "control_request"]
check("T12 interrupt wird nicht wiederholt", [x["sub"] for x in w] == ["initialize"], str(w))

print("\n%d von %d bestanden" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
