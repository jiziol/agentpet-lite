import assert from "node:assert/strict"
import { writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { pathToFileURL } from "node:url"
const root = process.argv[2], capture = root + "/frames.jsonl"
process.env.AGENTPET_CAPTURE = capture
writeFileSync(root + "/capture", `#!/usr/bin/env node
let data = "";
process.stdin.on("data", c => data += c);
process.stdin.on("end", () => require("node:fs").appendFileSync(process.env.AGENTPET_CAPTURE, data + "\\n"));
`)
chmodSync(root + "/capture", 0o700)
const { default: extension } = await import(pathToFileURL(root + "/pi.mjs"))
const handlers = new Map()
extension({ on: (name, handler) => handlers.set(name, handler) })
const ctx = (path) => ({ cwd: "/synthetic", sessionManager: { getSessionFile: () => path } })
const a = ctx("/synthetic/a.jsonl"), b = ctx("/synthetic/b.jsonl")
const emit = (name, event, context = a) => handlers.get(name)(event, context)
await emit("session_start", {})
await emit("agent_start", {})
await emit("ui_prompt_start", { kind: "select", title: "SECRET QUESTION" })
await emit("ui_prompt_start", { kind: "select", title: "duplicate" })
await emit("ui_prompt_start", { kind: "confirm", title: "SECRET COMMAND" }, b)
await emit("ui_prompt_end", {})
await emit("ui_prompt_start", { kind: "input", title: "SECRET" })
await emit("ui_prompt_end", {})
await emit("ui_prompt_end", {})
await emit("agent_end", { messages: [{role: "assistant", stopReason: "stop"}] })
// A low-level end followed by continuation must not mark the turn complete.
await emit("agent_start", {})
await emit("agent_end", { messages: [{role: "assistant", stopReason: "stop"}] })
await emit("agent_settled", { aborted: false })
await emit("ui_prompt_end", {}, b)
await emit("session_shutdown", {})
await emit("agent_start", {}, { sessionManager: { getSessionFile() { throw new Error("bad metadata") } } })
const frames = () => existsSync(capture) ? readFileSync(capture, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []
const until = Date.now() + 5000
while (!frames().some(f => f.hook_event_name === "session_shutdown")) {
  if (Date.now() >= until) throw new Error("Pi observer delivery timeout")
  await new Promise(r => setTimeout(r, 20))
}
const all = frames(), asks = all.filter(f => f.agentpet_human?.action === "asked"), replies = all.filter(f => f.agentpet_human?.action === "resolved")
assert.equal(asks.length, 3)
assert.deepEqual(asks.map(f => f.agentpet_human.kind), ["choice", "permission", "reply"])
assert.equal(new Set(asks.map(f => f.agentpet_human.request_ids[0])).size, 3)
assert.deepEqual(new Set(replies.map(f => f.agentpet_human.request_ids[0])), new Set(asks.map(f => f.agentpet_human.request_ids[0])))
assert.ok(replies.every(f => asks.some(a => a.session_id === f.session_id && a.agentpet_human.request_ids[0] === f.agentpet_human.request_ids[0])))
assert.ok(!JSON.stringify(all).includes("SECRET"))
assert.equal(all.filter(f => f.hook_event_name === "idle").length, 1)
assert.equal(all.filter(f => f.hook_event_name === "done").length, 1)
assert.ok(all.filter(f => f.hook_event_name === "done").every(f => f.turn_result === "completed"))
assert.ok(all.filter(f => f.hook_event_name !== "done").every(f => f.turn_result === undefined))
assert.equal(all.at(-1).hook_event_name, "session_shutdown", "shutdown handler must await the queued final frame")
assert.ok(all.every(f => f.session_id.startsWith("pi:/synthetic/")))
for (const [reason, aborted] of [["aborted", true], ["error", false], [undefined, false]]) {
  await emit("agent_start", {})
  await emit("agent_end", { messages: [{role: "assistant", stopReason: reason}] })
  await emit("agent_settled", { aborted })
  await emit("session_shutdown", {})
}
assert.equal(frames().filter(f => f.hook_event_name === "done").length, 1, "abort, error and unknown outcomes cannot report successful completion")
console.log("PASS: Pi observer, continuation/settlement, abort/error, awaited shutdown, parallel UI, ownership and privacy")
