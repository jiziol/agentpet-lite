import assert from "node:assert/strict"
import { readFileSync, existsSync, writeFileSync } from "node:fs"
import { createServer } from "node:net"
import { pathToFileURL } from "node:url"
const root = process.argv[2]
const capture = root + "/v2-frames.jsonl"
process.env.AGENTPET_CAPTURE = capture
assert.ok(process.env.CFFIXED_USER_HOME, "isolated home required")
const { default: plugin } = await import(pathToFileURL(root + "/v2.mjs"))
assert.equal(plugin.id, "agentpet-lite.observer.v2")
const directory = "/synthetic/v2-project", location = { directory }
const infos = new Map(), hooks = {}, pending = [], speech = []
let wake, sequence = 0, aborted = false
const server = createServer(socket => {
  let data = ""
  socket.on("data", chunk => { data += chunk; for (let pos; (pos = data.indexOf("\n")) >= 0;) { speech.push(JSON.parse(data.slice(0, pos))); data = data.slice(pos + 1) } })
})
await new Promise(resolve => server.listen(root + "/v2.sock", resolve))
const timers = [], original = globalThis.setInterval
globalThis.setInterval = (callback, ...args) => { if (args[0] === 30000) timers.push(callback); return original(callback, ...args) }
const cleanup = await plugin.setup({ location,
  session: { get: async ({ sessionID }, options) => {
    assert.ok(options.signal instanceof AbortSignal)
    if (!infos.has(sessionID)) throw new Error("not found")
    return infos.get(sessionID)
  } },
  tool: { hook: async (name, callback) => { hooks[name] = callback } },
  event: { async *subscribe({ signal }) {
    signal.addEventListener("abort", () => { aborted = true; wake?.() }, { once: true })
    while (!signal.aborted) {
      if (!pending.length) await new Promise(resolve => { wake = resolve })
      if (signal.aborted) break
      yield pending.shift()
    }
  } },
})
globalThis.setInterval = original
const frames = () => existsSync(capture) ? readFileSync(capture, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []
async function waitFor(predicate) {
  const until = Date.now() + 6000
  while (!predicate()) { if (Date.now() > until) throw new Error("V2 delivery timeout"); await new Promise(resolve => setTimeout(resolve, 15)) }
}
const sid = "ses_v2Root"
infos.set(sid, { id: sid, title: "Native V2", model: { id: "v2-model" }, location, time: { created: Date.now() } })
const send = (type, data, opts = {}) => {
  pending.push({ id: "evt_" + (++sequence), type, data: { sessionID: sid, ...data }, created: Date.now(), location,
    durable: { seq: sequence }, ...opts }); wake?.(); wake = undefined
}
send("session.execution.started", {})
send("session.inbox.delivered", { inboxID: "msg_user1" })
await waitFor(() => frames().some(f => f.turn_id === "msg_user1"))
send("session.step.started", { assistantMessageID: "msg_reply1", model: { id: "model-v2-live" } })
send("session.text.ended", { assistantMessageID: "msg_reply1", ordinal: 0, text: "Visible public answer" })
send("session.text.ended", { assistantMessageID: "msg_reply1", ordinal: 0, text: "duplicate must not replay" })
pending.push({ type: "session.reasoning.ended", get data() { throw new Error("private payload accessed") } }); wake?.(); wake = undefined
await waitFor(() => speech.length === 1)
assert.equal(speech[0].text, "Visible public answer")
assert.equal(speech[0].parent_id, "msg_user1")
await hooks["execute.before"]({ sessionID: sid, tool: "read", id: "call_1", input: { filePath: "/SECRET/private/README.md", text: "SECRET" } })
send("permission.asked", { id: "per_1", action: "SECRET", resources: ["SECRET"] })
send("form.created", { form: { id: "form_1", sessionID: sid, title: "SECRET", fields: [{ type: "string", options: [{ value: "SECRET" }] }] } })
await waitFor(() => frames().filter(f => f.event === "waiting").length === 2)
await hooks["execute.before"]({ sessionID: sid, tool: "shell", id: "call_2", input: { command: "git status --SECRET" } })
send("permission.replied", { requestID: "per_1", reply: "once" })
send("form.replied", { id: "form_1", answer: { secret: "SECRET" } })
await waitFor(() => frames().some(f => f.activity_id === "call_2"))
send("session.execution.succeeded", {})
send("session.idle", {})
send("session.text.ended", { assistantMessageID: "msg_reply1", ordinal: 1, text: "late body must not show" })
await waitFor(() => frames().some(f => f.event === "done"))
let all = frames()
assert.equal(all.filter(f => f.event === "done").length, 1)
assert.equal(all.at(-1).result, "completed")
assert.equal(speech.length, 1)
assert.ok(all.some(f => f.model === "model-v2-live"))
assert.ok(all.some(f => f.tool_input?.file_path === "README.md"))
assert.ok(!JSON.stringify(all).includes("SECRET"))
const waiting = all.findIndex(f => f.event === "waiting"), resumed = all.findIndex((f, i) => i > waiting && f.activity_id === "call_2")
assert.equal(all.slice(waiting, resumed).filter(f => f.agentpet_human?.action === "resolved").length, 2)
infos.set("ses_v2Child", { id: "ses_v2Child", parentID: sid, location })
send("session.execution.started", { sessionID: "ses_v2Child" })
send("session.execution.started", { sessionID: "ses_otherLocation" }, { location: { directory: "/other" } })
send("session.execution.started", {})
send("session.inbox.delivered", { inboxID: "msg_user2" })
send("session.execution.interrupted", { reason: "user" })
await waitFor(() => frames().some(f => f.turn_id === "msg_user2" && f.result === "cancelled"))
send("session.execution.started", {})
send("session.inbox.delivered", { inboxID: "msg_user3" })
send("session.execution.failed", { error: { type: "API", message: "SECRET" } })
await waitFor(() => frames().some(f => f.turn_id === "msg_user3" && f.result === "failed"))
send("session.execution.started", {})
send("session.inbox.delivered", { inboxID: "msg_user4" })
send("session.execution.interrupted", { reason: "shutdown" })
await waitFor(() => frames().some(f => f.turn_id === "msg_user4" && f.result === "unknown"))
send("session.execution.started", {})
send("session.inbox.delivered", { inboxID: "msg_user5" })
await waitFor(() => frames().some(f => f.turn_id === "msg_user5"))
timers[0]()
await waitFor(() => frames().some(f => f.turn_id === "msg_user5" && f.event === "heartbeat"))
send("session.renamed", { title: "Renamed V2" })
await waitFor(() => frames().some(f => f.title === "Renamed V2"))
await cleanup()
assert.ok(aborted)
assert.ok(frames().some(f => f.turn_id === "msg_user5" && f.result === "unknown"))
assert.ok(frames().every(f => !["ses_v2Child", "ses_otherLocation"].includes(f.session_id)))
assert.ok(!JSON.stringify(frames()).includes("SECRET"))
await new Promise(resolve => server.close(resolve))
console.log("PASS: V2 public API lifecycle, parallel form/permission waits, privacy, speech, child/location isolation, heartbeat and cleanup")
