#!/usr/bin/env python3
"""Drive Burrow --mcp over stdio and check it against the 2026-07-28 spec.

This is an end-to-end harness, not a unit test: it spawns the real signed
binary, speaks JSON-RPC at it, and asserts on what comes back.
"""
import json
import subprocess
import sys
import time

BIN = sys.argv[1] if len(sys.argv) > 1 else None
if not BIN:
    sys.exit(f"usage: {sys.argv[0]} <path-to-Burrow-binary>\nwithout it the harness fails inside Popen with a TypeError that says nothing useful")
VERSION = "2026-07-28"

FAILURES = []
PASSES = []


def check(name, cond, detail=""):
    if cond:
        PASSES.append(name)
    else:
        FAILURES.append(f"{name}: {detail}")


class Client:
    """One server process. Stateless era by default."""

    def __init__(self, capabilities=None, declare_version=VERSION):
        self.proc = subprocess.Popen(
            [BIN, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.caps = capabilities if capabilities is not None else {}
        self.declare_version = declare_version

    def meta(self):
        if self.declare_version is None:
            return None
        return {
            "io.modelcontextprotocol/protocolVersion": self.declare_version,
            "io.modelcontextprotocol/clientCapabilities": self.caps,
            "io.modelcontextprotocol/clientInfo": {"name": "conformance-harness", "version": "1.0"},
        }

    def send(self, method, params=None, raw=None, want_reply=True):
        if want_reply:
            self.n += 1
        if raw is not None:
            line = raw
        else:
            p = dict(params or {})
            m = self.meta()
            if m is not None:
                p["_meta"] = {**m, **p.get("_meta", {})}
            msg = {"jsonrpc": "2.0", "method": method, "params": p}
            # A notification carries no id — including one makes it a request.
            if want_reply:
                msg["id"] = self.n
            line = json.dumps(msg)
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        if not want_reply:
            return None
        out = self.proc.stdout.readline()
        if not out:
            raise RuntimeError(f"server closed the stream after {method}")
        return json.loads(out)

    def result(self, method, params=None):
        r = self.send(method, params)
        if "error" in r:
            raise AssertionError(f"{method} errored: {r['error']}")
        return r["result"]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


# ---------------------------------------------------------------- discovery

c = Client()
disc = c.result("server/discover")
check("discover.resultType", disc.get("resultType") == "complete", disc.get("resultType"))
check("discover.supportedVersions has latest", VERSION in disc.get("supportedVersions", []),
      disc.get("supportedVersions"))
check("discover.supportedVersions keeps legacy", "2024-11-05" in disc.get("supportedVersions", []))
check("discover.ttlMs", isinstance(disc.get("ttlMs"), int), disc.get("ttlMs"))
check("discover.cacheScope", disc.get("cacheScope") in ("public", "private"), disc.get("cacheScope"))
check("discover.capabilities.tools", "tools" in disc.get("capabilities", {}))
check("discover advertises tasks extension",
      "io.modelcontextprotocol/tasks" in disc.get("capabilities", {}).get("extensions", {}),
      disc.get("capabilities"))
check("discover.instructions", isinstance(disc.get("instructions"), str) and len(disc["instructions"]) > 50)
si = disc.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {})
check("discover _meta.serverInfo", si.get("name") == "burrow" and "version" in si, si)

# ------------------------------------------------------- no handshake needed
tl = c.result("tools/list")
check("tools/list works with no initialize", isinstance(tl.get("tools"), list), "no tools")
tools = tl["tools"]
check("tools/list.resultType", tl.get("resultType") == "complete")
check("tools/list.ttlMs", isinstance(tl.get("ttlMs"), int))
check("tools/list.cacheScope", tl.get("cacheScope") in ("public", "private"))
names = [t["name"] for t in tools]
check("tools/list deterministic order", names == sorted(names), names[:4])
check("tools/list count", len(tools) == 28, len(tools))

missing_ann = [t["name"] for t in tools if "annotations" not in t]
check("every tool has annotations", not missing_ann, missing_ann)
missing_title = [t["name"] for t in tools if "title" not in t]
check("every tool has a title", not missing_title, missing_title)

ro = {t["name"] for t in tools if t.get("annotations", {}).get("readOnlyHint")}
mutating = {"burrow_clean", "burrow_optimize", "burrow_uninstall", "burrow_purge", "burrow_installer"}
check("mutating tools are not readOnly", not (ro & mutating), sorted(ro & mutating))
check("23 read-only tools", len(ro) == 23, len(ro))
# By name, with .get: a server that omits a tool should FAIL that check and let
# the run reach its verdict, not raise StopIteration and kill the harness.
by_name = {t["name"]: t for t in tools}
clean = by_name.get("burrow_clean")
check("burrow_clean present", clean is not None)
check("burrow_clean destructiveHint",
      bool(clean) and clean.get("annotations", {}).get("destructiveHint") is True)
report = by_name.get("burrow_report")
check("burrow_report present", report is not None)
check("burrow_report has no outputSchema (markdown)",
      bool(report) and "outputSchema" not in report)
schema_count = sum(1 for t in tools if "outputSchema" in t)
check("27 tools declare outputSchema", schema_count == 27, schema_count)

# ------------------------------------------------------------- tools/call
r = c.result("tools/call", {"name": "burrow_info", "arguments": {}})
check("tools/call.resultType", r.get("resultType") == "complete")
check("tools/call content", r["content"][0]["type"] == "text")
check("tools/call structuredContent", isinstance(r.get("structuredContent"), dict),
      type(r.get("structuredContent")))
check("structuredContent mirrors text",
      r["structuredContent"] == json.loads(r["content"][0]["text"]))
check("tools/call _meta.serverInfo",
      r.get("_meta", {}).get("io.modelcontextprotocol/serverInfo", {}).get("name") == "burrow")

rep = c.result("tools/call", {"name": "burrow_report", "arguments": {"days": 7}})
check("markdown tool omits structuredContent", "structuredContent" not in rep,
      list(rep.keys()))

# --------------------------------------------------- newly exposed surfaces
audit = c.result("tools/call", {"name": "burrow_agent_audit", "arguments": {"limit": 5}})
ap = json.loads(audit["content"][0]["text"])
check("agent audit returns entries list", isinstance(ap.get("entries"), list), ap)
check("agent audit echoes its window", isinstance(ap.get("window_minutes"), int), ap)
anom = c.result("tools/call", {"name": "burrow_anomalies", "arguments": {}})
anp = json.loads(anom["content"][0]["text"])
check("anomalies returns findings list", isinstance(anp.get("findings"), list), anp)
check("anomalies states its basis", "24h" in anp.get("basis", ""), anp.get("basis"))
check("anomalies structuredContent", isinstance(anom.get("structuredContent"), dict))

# --------------------------------------------------------------- resources
rl = c.result("resources/list")
check("resources/list.ttlMs", isinstance(rl.get("ttlMs"), int))
check("resources/list.cacheScope", rl.get("cacheScope") in ("public", "private"))
uris = [x["uri"] for x in rl["resources"]]
check("resources include doctor", "burrow://doctor" in uris, uris)
check("resources count", len(uris) == 10, len(uris))

rt = c.result("resources/templates/list")
check("templates present", len(rt.get("resourceTemplates", [])) == 3, rt.get("resourceTemplates"))
check("templates.ttlMs", isinstance(rt.get("ttlMs"), int))

rr = c.result("resources/read", {"uri": "burrow://doctor"})
check("resources/read.contents", rr["contents"][0]["uri"] == "burrow://doctor")
check("resources/read.mimeType", rr["contents"][0]["mimeType"] == "application/json")
check("resources/read.ttlMs", isinstance(rr.get("ttlMs"), int))
check("resources/read is private", rr.get("cacheScope") == "private", rr.get("cacheScope"))
check("doctor payload parses", isinstance(json.loads(rr["contents"][0]["text"]).get("checks"), list))

rh = c.result("resources/read", {"uri": "burrow://history/30"})
check("template read works", "count" in json.loads(rh["contents"][0]["text"]))

bad = c.send("resources/read", {"uri": "burrow://nope"})
check("unknown resource is -32602", bad.get("error", {}).get("code") == -32602, bad.get("error"))
bad2 = c.send("resources/read", {"uri": "burrow://history/notanumber"})
check("bad template param is -32602", bad2.get("error", {}).get("code") == -32602, bad2.get("error"))

# ----------------------------------------------------------------- prompts
pl = c.result("prompts/list")
check("prompts present", len(pl.get("prompts", [])) == 5, len(pl.get("prompts", [])))
check("prompts/list.ttlMs", isinstance(pl.get("ttlMs"), int))
pg = c.result("prompts/get", {"name": "diagnose_slow_mac", "arguments": {"minutes": "120"}})
check("prompts/get messages", pg["messages"][0]["role"] == "user")
check("prompt interpolates argument", "120" in pg["messages"][0]["content"]["text"])
check("prompts/get.resultType", pg.get("resultType") == "complete")
pmissing = c.send("prompts/get", {"name": "investigate_process", "arguments": {}})
check("prompt missing required arg is -32602",
      pmissing.get("error", {}).get("code") == -32602, pmissing.get("error"))

# -------------------------------------------------------------- completion
comp = c.result("completion/complete", {
    "ref": {"type": "ref/resource", "uri": "burrow://processes/{metric}"},
    "argument": {"name": "metric", "value": "p"}})
vals = comp["completion"]["values"]
check("completion returns metrics", set(vals) == {"peak_cpu", "peak_mem"}, vals)

# ------------------------------------------------------- version negotiation
bad_ver = Client(declare_version="1999-01-01")
rv = bad_ver.send("tools/list")
err = rv.get("error", {})
check("unsupported version is -32022", err.get("code") == -32022, err)
check("-32022 carries supported list", VERSION in err.get("data", {}).get("supported", []), err.get("data"))
bad_ver.close()

# ------------------------------------------------------------- legacy client
legacy = Client(declare_version=None)
init = legacy.result("initialize", {"protocolVersion": "2024-11-05"})
check("initialize still answered", init.get("protocolVersion") == "2024-11-05", init.get("protocolVersion"))
check("initialize serverInfo", init["serverInfo"]["name"] == "burrow")
legacy.send("notifications/initialized", want_reply=False)
ltl = legacy.result("tools/list")
check("legacy tools/list works", len(ltl["tools"]) == 28, len(ltl.get("tools", [])))
lcall = legacy.result("tools/call", {"name": "burrow_info", "arguments": {}})
check("legacy tools/call works", "content" in lcall)
check("legacy client is never handed a task", lcall.get("resultType") == "complete",
      lcall.get("resultType"))
lping = legacy.result("ping")
check("legacy ping answered", lping.get("resultType") == "complete")
legacy.close()

# ------------------------------------------------------------------- errors
e1 = c.send("nope/nope")
check("unknown method is -32601", e1.get("error", {}).get("code") == -32601, e1.get("error"))
e2 = c.send(None, raw="this is not json")
check("garbage is -32700", e2.get("error", {}).get("code") == -32700, e2.get("error"))
e3 = c.send("tools/call", {"name": "burrow_nope"})
check("unknown tool is -32602", e3.get("error", {}).get("code") == -32602, e3.get("error"))
c.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
c.proc.stdin.flush()
e4 = c.send("tools/call", {"name": "burrow_history", "arguments": {"minutes": 0}})
check("notification got no reply (next id lines up)", e4.get("id") == c.n, e4.get("id"))
check("bad arguments is -32602", e4.get("error", {}).get("code") == -32602, e4.get("error"))

# -------------------------------------------------------------------- MRTR
elicit = Client(capabilities={"elicitation": {"form": {}}})
mr = elicit.result("tools/call", {"name": "burrow_uninstall", "arguments": {}})
check("MRTR returns input_required", mr.get("resultType") == "input_required", mr.get("resultType"))
check("MRTR asks for apps", "apps" in mr.get("inputRequests", {}), mr.get("inputRequests"))
req = mr["inputRequests"]["apps"]
check("MRTR uses elicitation/create", req["method"] == "elicitation/create", req.get("method"))
check("MRTR has requestedSchema", "requestedSchema" in req["params"])
state = mr["requestState"]
check("MRTR requestState is a string", isinstance(state, str))

retry = elicit.result("tools/call", {
    "name": "burrow_uninstall", "requestState": state,
    "inputResponses": {"apps": {"action": "accept", "content": {"apps": "Some App"}}}})
payload = json.loads(retry["content"][0]["text"])
check("MRTR retry reaches the tool", payload.get("command") == "uninstall", payload)
check("MRTR retry is still gated", payload.get("ran") is False, payload)

declined = elicit.result("tools/call", {
    "name": "burrow_uninstall", "requestState": state,
    "inputResponses": {"apps": {"action": "decline"}}})
dp = json.loads(declined["content"][0]["text"])
check("MRTR decline is in-band, not an error", dp.get("declined") is True, dp)

# A client with no elicitation capability must still get the old behaviour.
plain = c.send("tools/call", {"name": "burrow_uninstall", "arguments": {}})
check("no elicitation capability => plain argument error",
      plain.get("error", {}).get("code") == -32602, plain.get("error"))
elicit.close()

# ------------------------------------------------------------------- safety
#
# NEVER pass confirm:true from this harness. It runs against the real user
# defaults, so if the "Let agents run cleanups" opt-in happens to be ON, a
# confirm:true here performs a real deletion on this machine. The gate's
# refusal path belongs in a unit test with a scratch defaults suite
# (MCPConformanceTests), not in an end-to-end run. What we check here is the
# only thing that is safe to check live: that omitting confirm previews.
gate = c.result("tools/call", {"name": "burrow_clean", "arguments": {}})
gp = json.loads(gate["content"][0]["text"])
check("clean without confirm is a dry run",
      gp.get("dry_run") is True and gp.get("ran") is False, {k: gp.get(k) for k in ("dry_run", "ran")})
check("dry run still reports a command", gp.get("command") == "clean", gp.get("command"))

# -------------------------------------------------------------------- tasks
# Every spawned server gets closed even if a check below raises -- otherwise a
# single unexpected payload leaves Burrow processes running AND swallows the
# verdict the run exists to print.
tc = None
try:
    tc = Client(capabilities={"extensions": {"io.modelcontextprotocol/tasks": {}}})
    tr = tc.result("tools/call", {"name": "burrow_analyze",
                                  "arguments": {"path": "/usr/share/dict", "depth": 1}})
    check("task handle returned", tr.get("resultType") == "task", tr.get("resultType"))
    check("task has taskId", isinstance(tr.get("taskId"), str), tr)
    check("task starts working", tr.get("status") == "working", tr.get("status"))
    check("task has pollIntervalMs", isinstance(tr.get("pollIntervalMs"), int))
    check("task has ttlMs", tr.get("ttlMs") is None or isinstance(tr.get("ttlMs"), (int, float)))
    check("task timestamps", "createdAt" in tr and "lastUpdatedAt" in tr, tr)

    task_id = tr["taskId"]
    deadline = time.time() + 120
    final = None
    while time.time() < deadline:
        got = tc.result("tasks/get", {"taskId": task_id})
        if got["status"] in ("completed", "failed", "cancelled"):
            final = got
            break
        time.sleep(0.4)
    check("task reaches a terminal state", final is not None, "timed out polling")
    if final:
        check("task completed", final["status"] == "completed", final.get("statusMessage"))
        check("completed task carries result", isinstance(final.get("result"), dict), final.get("result"))
        if isinstance(final.get("result"), dict):
            check("task result is a CallToolResult", "content" in final["result"], final["result"].keys())

    unknown = tc.send("tasks/get", {"taskId": "nope"})
    check("unknown task is -32602", unknown.get("error", {}).get("code") == -32602, unknown.get("error"))

    # cancel a fresh one
    tr2 = tc.result("tools/call", {"name": "burrow_analyze", "arguments": {"path": "/usr", "depth": 2}})
    cancelled = tc.result("tasks/cancel", {"taskId": tr2["taskId"]})
    check("tasks/cancel acks", cancelled.get("resultType") == "complete", cancelled)
    after = tc.result("tasks/get", {"taskId": tr2["taskId"]})
    check("cancelled task reports cancelled", after["status"] == "cancelled", after.get("status"))
    upd = tc.result("tasks/update", {"taskId": tr2["taskId"], "inputResponses": {}})
    check("tasks/update acks", upd.get("resultType") == "complete", upd)

    # A non-long-running tool must stay synchronous even for a tasks client.
    sync = tc.result("tools/call", {"name": "burrow_info", "arguments": {}})
    check("short tools stay synchronous", sync.get("resultType") == "complete", sync.get("resultType"))
finally:
    # tc may be None if its own construction raised.
    if tc is not None:
        tc.close()
    c.close()

# ------------------------------------------------------------------ verdict
print(f"passed {len(PASSES)}")
for f in FAILURES:
    print("FAIL " + f)
print("FAILURES:", len(FAILURES))
sys.exit(1 if FAILURES else 0)
