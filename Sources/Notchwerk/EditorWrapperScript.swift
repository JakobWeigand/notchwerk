import Foundation

/// Die beiden Skripte, die Notchwerk auf Wunsch nach ~/.claude-notch/ schreibt (siehe EditorWrapper).
/// Sie sind als Text hier eingebettet, damit die App ohne Zusatzdateien auskommt.
enum EditorWrapperScript {
    /// Wird mit `claudeCode.claudeProcessWrapper` eingetragen. Ein kleines sh-Skript, das in jedem Zweifel
    /// `claude` unverändert startet (kein Ausweichkonto eingetragen, kein Python da) und sonst das Python-Skript.
    static let shell = #"""
    #!/bin/sh
    # Von Notchwerk angelegt (Version 1). Wird in VS Code oder Positron als claudeCode.claudeProcessWrapper
    # eingetragen und bekommt als erstes Argument den Pfad zu claude. Ohne Ausweichkonto startet es claude
    # unverändert. Siehe README, Abschnitt „Editor (Positron, VS Code)“.
    claude="$1"
    shift
    if [ -z "$NOTCHWERK_FALLBACK_CONFIG_DIR" ]; then
      exec "$claude" "$@"
    fi
    py=""
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
      if [ -x "$candidate" ]; then py="$candidate"; break; fi
    done
    # Das Python von macOS (/usr/bin/python3) fragt ohne Command Line Tools nach der Installation. Dann lieber ohne.
    if [ -z "$py" ] && [ -x /usr/bin/python3 ] && xcode-select -p >/dev/null 2>&1; then py=/usr/bin/python3; fi
    script="$(dirname "$0")/claude-wrapper.py"
    if [ -z "$py" ] || [ ! -f "$script" ]; then
      exec "$claude" "$@"
    fi
    exec "$py" "$script" "$claude" "$@"
    """#

    /// Wählt das Konto und wechselt bei einem Limit. Läuft mit dem Python von macOS (3.9), ohne Zusatzpakete.
    static let python = #"""
    #!/usr/bin/env python3
    # Von Notchwerk angelegt. Wird vom sh-Skript claude-wrapper gestartet:  claude-wrapper.py <claude> <Argumente …>
    #
    # Umgebung (aus claudeCode.environmentVariables):
    #   CLAUDE_CONFIG_DIR               Hauptkonto (nicht gesetzt = Standardkonto ~/.claude)
    #   NOTCHWERK_FALLBACK_CONFIG_DIR   Ausweichkonto ("default" = Standardkonto)
    #   NOTCHWERK_SEAMLESS=1            bei einem Limit mitten in der Unterhaltung zum Ausweichkonto wechseln
    #
    # Ohne NOTCHWERK_SEAMLESS wählt das Skript nur beim Start das Konto, das nicht am Limit ist (Stand aus
    # ~/.claude-notch/limits.json, den Notchwerk schreibt), und startet claude dann unverändert.
    # Mit NOTCHWERK_SEAMLESS=1 steht es zwischen Editor und claude, reicht alles unverändert durch und
    # greift nur ein, wenn claude meldet, dass das Limit erreicht ist: Dann beendet es diesen claude, kopiert
    # das Protokoll der Sitzung zum Ausweichkonto, startet claude dort mit --resume, wiederholt die Start-
    # Anfragen und die gescheiterte Nachricht und leitet ab da die Antworten des neuen claude weiter.
    # Es schreibt nie etwas aus der Unterhaltung in Logdateien.

    import collections
    import json
    import os
    import re
    import shutil
    import signal
    import subprocess
    import sys
    import threading
    import time

    NOTCHWERK_WRAPPER_VERSION = 1

    HOME = os.path.expanduser("~")
    DEFAULT_DIR = os.path.join(HOME, ".claude")
    NOTCH_DIR = os.path.join(HOME, ".claude-notch")
    LIMITS_FILE = os.path.join(NOTCH_DIR, "limits.json")
    LOG_FILE = os.path.join(NOTCH_DIR, "wrapper.log")
    SESSION_ID = re.compile(r"^[0-9A-Fa-f-]{8,64}$")
    MAX_SWITCHES = 2
    # Diese Steuer-Anfragen des Editors prägen den Zustand von claude und werden beim Wechsel wiederholt.
    REPLAY = ("initialize", "set_permission_mode", "set_model", "set_max_thinking_tokens",
              "set_mcp_permission_mode_override", "set_prompt_suggestions_paused", "mcp_set_servers")
    CONTINUE_TEXT = ("Your previous attempt was cut off because the account hit its usage limit. "
                     "Please continue exactly where you left off.")


    def log(message):
        """Kurze Betriebsmeldungen, nie Inhalt aus der Unterhaltung."""
        try:
            os.makedirs(NOTCH_DIR, mode=0o700, exist_ok=True)
            if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 100 * 1024:
                os.remove(LOG_FILE)
            fd = os.open(LOG_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            with os.fdopen(fd, "a") as f:
                f.write("%s [%d] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), os.getpid(), message))
        except Exception:
            pass


    def norm(path):
        if not path:
            return None
        p = os.path.expanduser(path)
        while len(p) > 1 and p.endswith("/"):
            p = p[:-1]
        return p


    class Account(object):
        def __init__(self, config):
            # config: Wert für CLAUDE_CONFIG_DIR, oder None, wenn die Variable ungesetzt bleibt. Beim
            # Standardkonto muss sie ungesetzt bleiben: Claude Code leitet aus ihr den Namen des Schlüssel-
            # bund-Eintrags ab und fände die Anmeldung sonst nicht.
            self.config = config
            self.dir = norm(config) or DEFAULT_DIR
            self.id = "default" if self.dir == DEFAULT_DIR else self.dir

        def env(self, base):
            env = dict(base)
            env.pop("CLAUDE_CONFIG_DIR", None)
            if self.config:
                env["CLAUDE_CONFIG_DIR"] = self.config
            return env


    def blocked_until(account):
        """Bis wann das Konto laut Notchwerk am Limit ist (0 = nicht bekannt oder frei)."""
        try:
            with open(LIMITS_FILE) as f:
                data = json.load(f)
            value = (data.get("accounts") or {}).get(account.id, {}).get("blockedUntil")
            return float(value) if value else 0.0
        except Exception:
            return 0.0


    def is_blocked(account):
        return blocked_until(account) > time.time()


    def find_transcript(config_dir, session_id):
        base = os.path.join(config_dir, "projects")
        try:
            folders = os.listdir(base)
        except OSError:
            return None
        for folder in folders:
            path = os.path.join(base, folder, session_id + ".jsonl")
            if os.path.isfile(path):
                return path, folder
        return None


    def sync_transcript(session_id, source_dir, target_dir):
        """Kopiert das Protokoll der Sitzung zum anderen Konto, falls dort keins oder ein älteres liegt.
        Gibt zurück, ob die Sitzung beim Zielkonto jetzt fortgesetzt werden kann."""
        if not session_id or not SESSION_ID.match(session_id):
            return False
        found = find_transcript(source_dir, session_id)
        if not found:
            return find_transcript(target_dir, session_id) is not None
        path, folder = found
        target_folder = os.path.join(target_dir, "projects", folder)
        target = os.path.join(target_folder, session_id + ".jsonl")
        try:
            os.makedirs(target_folder, mode=0o700, exist_ok=True)
            if os.path.exists(target) and os.path.getmtime(target) >= os.path.getmtime(path):
                return True
            temp = target + ".notchwerk-tmp"
            shutil.copyfile(path, temp)
            os.chmod(temp, 0o600)
            os.replace(temp, target)
            return True
        except OSError as error:
            log("Protokoll konnte nicht kopiert werden: %s" % error.__class__.__name__)
            return False


    def session_from_args(args):
        for i, arg in enumerate(args):
            if arg in ("--resume", "-r", "--session-id") and i + 1 < len(args) and not args[i + 1].startswith("-"):
                return args[i + 1]
            for prefix in ("--resume=", "--session-id="):
                if arg.startswith(prefix):
                    return arg[len(prefix):]
        return None


    def strip_session_args(args):
        out = []
        i = 0
        while i < len(args):
            arg = args[i]
            if arg in ("--resume", "-r"):
                i += 2 if i + 1 < len(args) and not args[i + 1].startswith("-") else 1
                continue
            if arg == "--session-id":
                i += 2
                continue
            if arg.startswith("--resume=") or arg.startswith("--session-id=") or arg in ("--continue", "-c", "--fork-session"):
                i += 1
                continue
            out.append(arg)
            i += 1
        return out


    def looks_like_limit(text):
        lower = (text or "").lower()
        return "limit" in lower and ("hit your" in lower or "reached" in lower or "resets" in lower)


    class Proxy(object):
        def __init__(self, claude, args, base_env, accounts, start):
            self.claude = claude
            self.args = args
            self.base_env = base_env
            self.accounts = accounts
            self.current = start
            self.lock = threading.RLock()
            self.out = sys.stdout.buffer
            self.child = None
            self.gen = 0
            self.pending = collections.deque()   # Nachrichten von dir, auf die noch kein Ergebnis kam
            self.controls = collections.OrderedDict()
            self.session_id = session_from_args(args)
            self.turn_has_output = False
            self.switching = False
            self.switches = 0
            self.local_blocks = {}               # Konten, von denen wir gerade wegen eines Limits gewechselt sind
            self.swallow_ids = set()
            self.suppress_init = False
            self.backlog = []
            self.stdin_eof = False
            self.done = threading.Event()
            self.exit_code = 0

        # ---- Start und Ende ----

        def run(self):
            for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                signal.signal(sig, self.on_signal)
            self.spawn(self.current, self.args)
            threading.Thread(target=self.read_stdin, daemon=True).start()
            self.done.wait()
            try:
                self.out.flush()
            except Exception:
                pass
            os._exit(self.exit_code)

        def on_signal(self, number, frame):
            with self.lock:
                child = self.child
                self.exit_code = 128 + number
            if child is not None and child.poll() is None:
                child.terminate()
            self.done.set()

        def spawn(self, index, args):
            account = self.accounts[index]
            child = subprocess.Popen([self.claude] + args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=None, env=account.env(self.base_env))
            with self.lock:
                self.gen += 1
                gen = self.gen
                self.child = child
            threading.Thread(target=self.pump, args=(child, gen), daemon=True).start()
            return child

        def pump(self, child, gen):
            try:
                for line in iter(child.stdout.readline, b""):
                    self.on_child_line(gen, line)
            except Exception as error:
                log("Fehler beim Lesen der Ausgabe: %s" % error.__class__.__name__)
            code = child.wait()
            with self.lock:
                if gen != self.gen:
                    return   # ein Prozess, den wir selbst beendet haben
                self.exit_code = code if code >= 0 else 128 - code
            self.done.set()

        # ---- Ausgabe von claude ----

        def on_child_line(self, gen, line):
            obj = None
            if len(line) < 4 * 1024 * 1024:
                try:
                    obj = json.loads(line)
                except ValueError:
                    obj = None
            with self.lock:
                if gen != self.gen:
                    return
                verdict = self.classify(obj)
                if verdict == "swallow":
                    return
                if verdict == "limit" and self.may_switch():
                    self.switching = True
                    self.gen += 1   # alles, was der alte Prozess noch schickt, wird ignoriert
                    old = self.child
                else:
                    self.forward(line, obj)
                    return
            self.switch(old)

        def classify(self, obj):
            if not isinstance(obj, dict):
                return "forward"
            kind = obj.get("type")
            if kind == "rate_limit_event":
                info = obj.get("rate_limit_info") or {}
                return "limit" if info.get("status") == "rejected" else "forward"
            if kind == "control_response" and self.swallow_ids:
                request_id = (obj.get("response") or {}).get("request_id")
                if request_id in self.swallow_ids:
                    self.swallow_ids.discard(request_id)
                    return "swallow"
            if kind == "system" and obj.get("subtype") == "init" and self.suppress_init:
                self.suppress_init = False   # der Editor kennt die Sitzung schon
                return "swallow"
            if kind == "assistant":
                message = obj.get("message") or {}
                if message.get("model") == "<synthetic>":
                    text = " ".join(b.get("text", "") for b in message.get("content") or [] if isinstance(b, dict))
                    if looks_like_limit(text):
                        return "limit"
            if kind == "result" and obj.get("is_error") and looks_like_limit(obj.get("result")):
                return "limit"
            return "forward"

        def may_switch(self):
            if self.switching or self.switches >= MAX_SWITCHES:
                return False
            target = self.accounts[1 - self.current]
            # Nicht zurück zu einem Konto springen, von dem wir eben wegen seines Limits gewechselt sind.
            if self.local_blocks.get(target.id, 0) > time.time():
                return False
            return not is_blocked(target)

        def forward(self, line, obj):
            if isinstance(obj, dict):
                kind = obj.get("type")
                if self.session_id is None and isinstance(obj.get("session_id"), str):
                    self.session_id = obj["session_id"]
                if kind in ("assistant", "stream_event"):
                    self.turn_has_output = True
                elif kind == "result":
                    if self.pending:
                        self.pending.popleft()
                    self.turn_has_output = False
            try:
                self.out.write(line)
                self.out.flush()
            except Exception:
                self.exit_code = 1
                self.done.set()

        # ---- Eingabe vom Editor ----

        def read_stdin(self):
            try:
                for line in iter(sys.stdin.buffer.readline, b""):
                    self.on_stdin_line(line)
            except Exception as error:
                log("Fehler beim Lesen der Eingabe: %s" % error.__class__.__name__)
            with self.lock:
                self.stdin_eof = True
                if not self.switching:
                    self.close_stdin(self.child)

        def on_stdin_line(self, line):
            if not line.endswith(b"\n"):
                line += b"\n"
            obj = None
            try:
                obj = json.loads(line)
            except ValueError:
                obj = None
            with self.lock:
                if isinstance(obj, dict):
                    kind = obj.get("type")
                    if kind == "user":
                        self.pending.append(line)
                        if len(self.pending) == 1:
                            self.turn_has_output = False
                    elif kind == "control_request":
                        subtype = (obj.get("request") or {}).get("subtype")
                        if subtype in REPLAY and not (subtype == "initialize" and "initialize" in self.controls):
                            self.controls.pop(subtype, None)
                            self.controls[subtype] = obj
                if self.switching:
                    self.backlog.append(line)
                    return
                self.write(self.child, line)

        @staticmethod
        def write(child, data):
            try:
                child.stdin.write(data)
                child.stdin.flush()
            except (BrokenPipeError, ValueError, OSError):
                pass

        @staticmethod
        def close_stdin(child):
            try:
                child.stdin.close()
            except Exception:
                pass

        # ---- Wechsel zum anderen Konto ----

        def switch(self, old):
            try:
                self.do_switch(old)
            except Exception as error:
                log("Wechsel fehlgeschlagen: %s" % error.__class__.__name__)
                with self.lock:
                    self.exit_code = 1
                self.done.set()

        def do_switch(self, old):
            self.close_stdin(old)
            if old.poll() is None:
                old.terminate()
                try:
                    old.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    old.kill()
                    old.wait()

            with self.lock:
                source = self.accounts[self.current]
                target_index = 1 - self.current
                target = self.accounts[target_index]
                session_id = self.session_id
                pending = list(self.pending)
                controls = list(self.controls.values())
                mid_turn = self.turn_has_output
            log("Limit bei %s erkannt, wechsle zu %s" % (source.id, target.id))
            with self.lock:
                self.local_blocks[source.id] = time.time() + 600

            can_resume = sync_transcript(session_id, source.dir, target.dir)
            args = strip_session_args(self.args)
            if session_id and SESSION_ID.match(session_id):
                args += ["--resume", session_id] if can_resume else ["--session-id", session_id]

            with self.lock:
                self.current = target_index
                self.switches += 1
                self.suppress_init = True
                self.turn_has_output = False
            child = self.spawn(target_index, args)

            # Was der Editor beim Start eingestellt hat, dem neuen claude noch einmal sagen. Die Antworten darauf
            # kennt der Editor schon und bekommt sie nicht noch einmal.
            for original in controls:
                request = dict(original)
                request["request_id"] = "%s-nw%d" % (original.get("request_id", "r"), self.switches)
                with self.lock:
                    self.swallow_ids.add(request["request_id"])
                self.write(child, (json.dumps(request) + "\n").encode("utf-8"))

            # Dann die Nachricht, die gescheitert ist. Hatte claude schon geantwortet, sagt es dem neuen: weitermachen.
            replay = pending
            if mid_turn and pending:
                message = {"type": "user", "parent_tool_use_id": None,
                           "message": {"role": "user", "content": [{"type": "text", "text": CONTINUE_TEXT}]}}
                if session_id:
                    message["session_id"] = session_id
                replay = [(json.dumps(message) + "\n").encode("utf-8")] + pending[1:]
            for line in replay:
                self.write(child, line)

            with self.lock:
                self.switching = False
                backlog, self.backlog = self.backlog, []
                for line in backlog:
                    self.write(child, line)
                if self.stdin_eof:
                    self.close_stdin(child)


    def main():
        if len(sys.argv) < 2:
            sys.exit(2)
        claude = sys.argv[1]
        args = sys.argv[2:]
        env = dict(os.environ)

        primary = Account(os.environ.get("CLAUDE_CONFIG_DIR") or None)
        raw = os.environ.get("NOTCHWERK_FALLBACK_CONFIG_DIR", "").strip()
        fallback = Account(None if raw == "default" else raw) if raw else None
        if fallback is None or fallback.id == primary.id:
            os.execve(claude, [claude] + args, env)

        accounts = [primary, fallback]
        # Schon beim Start das Konto nehmen, das nicht am Limit ist.
        start = 1 if is_blocked(primary) and not is_blocked(fallback) else 0
        if start == 1:
            log("Start mit %s, weil %s am Limit ist" % (fallback.id, primary.id))
            sync_transcript(session_from_args(args), primary.dir, fallback.dir)

        if os.environ.get("NOTCHWERK_SEAMLESS") != "1":
            os.execve(claude, [claude] + args, accounts[start].env(env))

        Proxy(claude, args, env, accounts, start).run()


    if __name__ == "__main__":
        try:
            main()
        except SystemExit:
            raise
        except Exception as error:
            # Im Zweifel claude unverändert starten, damit der Editor nie ohne Claude dasteht.
            log("Wrapper-Fehler: %s" % error.__class__.__name__)
            if len(sys.argv) >= 2:
                os.execve(sys.argv[1], [sys.argv[1]] + sys.argv[2:], dict(os.environ))
            raise
    """#
}
