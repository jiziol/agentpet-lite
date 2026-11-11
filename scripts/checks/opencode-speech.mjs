import assert from "node:assert/strict"
import { createServer } from "node:net"
import { pathToFileURL } from "node:url"
const [plugin, socketPath] = process.argv.slice(2)
process.argv.push("run") // No navigation bridge in this isolated protocol fixture.
const timers = new Map()
const interval = globalThis.setInterval
globalThis.setInterval = (fn, ms) => { timers.set(ms, fn); return { unref() {} } }
const { AgentPet } = await import(pathToFileURL(plugin))
const hook = await AgentPet({ directory: "/synthetic", client: { session: { get: async ({ path }) => ({ data: {
  id: path.id, title: "Fixture", parentID: path.id === "ses_Child" ? "ses_One" : undefined } }) } } })
globalThis.setInterval = interval
const frames = []
let connections = 0
const server = createServer(socket => {
  connections++; let bytes = ""
  socket.on("data", chunk => bytes += chunk)
  socket.on("end", () => { frames.push(...bytes.trim().split("\n").filter(Boolean).map(JSON.parse)); socket.end() })
})
const listen = () => new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve) })
await listen()
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
const flush = async () => { timers.get(500)(); await wait(70) }
const event = (type, properties) => hook.event({ event: { type, properties } })
const begin = sid => hook["chat.message"]({ sessionID: sid }, { message: { id: "msg_User" } })
const assistant = (sid, parentID = "msg_User", role = "assistant", id = "msg_Assistant") => event("message.updated", { info: { sessionID: sid, id, parentID, role } })
const text = (sid, value, options = {}) => event("message.part.updated", { delta: "DO-NOT-APPEND", part: {
  sessionID: sid, id: "prt_Text", messageID: "msg_Assistant", type: "text", text: value, ...options } })
const sid = "ses_One"
await begin(sid)
await text(sid, "part-before-metadata")
await flush(); assert.equal(frames.length, 0)
await assistant(sid)
await flush(); assert.equal(frames.at(-1).text, "part-before-metadata")
const count = frames.length
await begin("ses_Child"); await assistant("ses_Child"); await text("ses_Child", "child must not create a second bubble")
await flush(); assert.equal(frames.length, count)
await text(sid, "part-before-metadata"); await flush(); assert.equal(frames.length, count)
for (let i = 0; i < 1000; i++) await text(sid, `snapshot-${i}`)
await flush(); assert.equal(frames.length, count + 1); assert.equal(frames.at(-1).text, "snapshot-999")
assert.ok(!frames.at(-1).text.includes("DO-NOT-APPEND"))
for (const extra of [{ type: "reasoning" }, { messageID: "msg_User" }, { type: "tool" }]) await text(sid, "SECRET", extra)
await assistant(sid, "msg_Old", "assistant", "msg_OldAssistant")
await text(sid, "SECRET", { messageID: "msg_OldAssistant" })
await assistant(sid, undefined, "user", "msg_User")
await flush(); assert.equal(frames.length, count + 1)
await text(sid, "SECRET", { ignored: true })
await flush(); assert.equal(frames.at(-1).mode, "withdraw"); assert.equal(frames.at(-1).text, "")
await text(sid, "visible-again")
await flush(); assert.equal(frames.at(-1).text, "visible-again")
await event("message.part.removed", { sessionID: sid, partID: "prt_Text", messageID: "msg_Assistant" })
await flush(); assert.equal(frames.at(-1).mode, "withdraw")
const afterPartRemoval = frames.length
await text(sid, "must-not-revive-removed-part"); await flush(); assert.equal(frames.length, afterPartRemoval)
await text(sid, "removed-message", { id: "prt_Second" })
await flush()
await event("message.removed", { sessionID: sid, messageID: "msg_Assistant" })
await flush(); assert.equal(frames.at(-1).mode, "withdraw")
const before = frames.length
await assistant(sid); await text(sid, "REMOVED-MESSAGE", { id: "prt_Third" }); await flush(); assert.equal(frames.length, before)
await hook["chat.message"]({ sessionID: sid }, { message: { id: "msg_Intermediate" } })
await assistant(sid, "msg_Intermediate"); await text(sid, "OLD-PENDING")
await hook["chat.message"]({ sessionID: sid }, { message: { id: "msg_New" } })
await text(sid, "OLD-PARENT")
await assistant(sid, "msg_New"); await text(sid, "current-turn")
await flush(); assert.equal(frames.length, before + 1); assert.equal(frames.at(-1).parent_id, "msg_New")
await text(sid, "CANCELLED-PENDING")
await event("session.error", { sessionID: sid, error: { name: "MessageAbortedError" } })
await flush(); assert.equal(frames.length, before + 1)
await begin("ses_Deleted"); await assistant("ses_Deleted"); await text("ses_Deleted", "DELETED")
await event("session.deleted", { info: { id: "ses_Deleted" } }); await flush(); assert.equal(frames.length, before + 1)
await begin("ses_RemovalBound"); await assistant("ses_RemovalBound")
for (let n = 0; n < 17; n++) await event("message.part.removed", { sessionID: "ses_RemovalBound", partID: `prt_Removed${n}` })
await assistant("ses_RemovalBound"); await text("ses_RemovalBound", "SATURATED-STATE")
await flush(); assert.ok(!frames.some(f => f.session_id === "ses_RemovalBound"))
for (let n = 0; n < 140; n++) {
  const id = `ses_Load${n}`; await begin(id); await assistant(id); await text(id, "字".repeat(5000))
}
for (let n = 0; n < 5; n++) await flush()
const load = frames.filter(f => f.session_id.startsWith("ses_Load"))
assert.ok(load.length <= 128 && load.length >= 100)
assert.ok(load.every(f => Buffer.byteLength(f.text) <= 2048))
assert.ok(frames.every((f, i) => i === 0 || f.revision > frames[i - 1].revision))
assert.ok(!JSON.stringify(frames).includes("SECRET"))
await new Promise(resolve => server.close(resolve))
await begin("ses_Offline"); await assistant("ses_Offline"); await text("ses_Offline", "OFFLINE")
await flush(); await listen(); const offline = frames.length
await flush(); assert.equal(frames.length, offline, "failed batches must not replay after reconnect")
await text("ses_Offline", "fresh-after-reconnect"); await flush(); assert.equal(frames.at(-1).text, "fresh-after-reconnect")
await new Promise(resolve => server.close(resolve))
console.log(`PASS: OpenCode visible snapshots, role/parent/part fences, withdrawal, burst coalescing, bounded load and offline drop (${frames.length} frames, ${connections} connections)`)
