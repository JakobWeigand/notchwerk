#!/usr/bin/env python3
# Attrappe von claude für Tests: spricht das Stream-Protokoll und kann ein Limit melden.
import json, os, sys
LOG = os.environ["FAKE_LOG"]
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or "default"
args = sys.argv[1:]
def log(**kw):
    kw["cfg"] = cfg
    with open(LOG, "a") as f: f.write(json.dumps(kw) + "\n")
sid = None
for i, a in enumerate(args):
    if a in ("--resume", "--session-id") and i + 1 < len(args): sid = args[i + 1]
sid = sid or "aaaaaaaa-0000-4000-8000-000000000001"
log(event="start", args=args, resumed="--resume" in args)
LIMIT_FILE = os.environ.get("FAKE_LIMIT_FILE")
def is_limited():
    return cfg in [x for x in os.environ.get("FAKE_LIMITED", "").split(",") if x] and (not LIMIT_FILE or os.path.exists(LIMIT_FILE))
def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
home = os.environ["HOME"]
cfgdir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
def save_transcript():
    d = os.path.join(cfgdir, "projects", "-test-project"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, sid + ".jsonl"), "a") as f: f.write(json.dumps({"type": "user", "marker": "x"}) + "\n")
for line in sys.stdin:
    obj = json.loads(line)
    sub = (obj.get("request") or {}).get("subtype")
    text = ""
    if obj.get("type") == "user":
        c = obj["message"]["content"]
        text = c if isinstance(c, str) else " ".join(b.get("text", "") for b in c)
    log(event="stdin", type=obj.get("type"), sub=sub, text=text)
    if obj.get("type") == "control_request":
        out({"type": "control_response", "response": {"subtype": "success", "request_id": obj["request_id"], "response": {"ok": True}}})
    elif obj.get("type") == "user":
        out({"type": "system", "subtype": "init", "session_id": sid})
        if is_limited():
            if os.environ.get("FAKE_MIDTURN") == "1":
                out({"type": "assistant", "session_id": sid, "message": {"model": "fake", "content": [{"type": "text", "text": "teilweise"}]}})
            out({"type": "rate_limit_event", "session_id": sid, "rate_limit_info": {"status": "rejected", "rateLimitType": "five_hour", "resetsAt": 1791735600}})
            out({"type": "assistant", "session_id": sid, "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "You've hit your session limit · resets 6:20pm"}]}})
            out({"type": "result", "subtype": "success", "is_error": True, "session_id": sid, "result": "You've hit your session limit · resets 6:20pm"})
        else:
            out({"type": "stream_event", "session_id": sid, "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": "hi"}}})
            out({"type": "assistant", "session_id": sid, "message": {"model": "fake", "content": [{"type": "text", "text": "Antwort von %s auf: %s" % (cfg, text)}]}})
            out({"type": "result", "subtype": "success", "is_error": False, "session_id": sid, "result": "Antwort von %s auf: %s" % (cfg, text)})
            save_transcript()
log(event="stdin-eof")
