import assert from "node:assert/strict"
import { readFileSync, existsSync } from "node:fs"
import { pathToFileURL } from "node:url"
const root = process.argv[2]
process.argv.push("run")
process.env.AGENTPET_CAPTURE = root + "/subagent-frames.jsonl"
const { AgentPet } = await import(pathToFileURL(root + "/agentpet.mjs"))
const queries = new Map(), releases = new Map()
const hook = await AgentPet({ directory: "/synthetic/project", client: { session: {
  get: async ({ path, signal }) => {
    assert.ok(signal instanceof AbortSignal)
    queries.set(path.id, (queries.get(path.id) || 0) + 1)
    if (path.id.startsWith("ses_Lookup")) return new Promise(() => {})
    if (path.id === "ses_Unavailable") throw Error("fixture metadata unavailable")
    if (path.id === "ses_Race") return new Promise(resolve => releases.set(path.id, resolve))
    if (path.id === "ses_WrongID") return { data: { id: "ses_Another" } }
    if (path.id === "ses_Self") return { data: { id: path.id, parentID: path.id } }
    const parentID = { ses_Child: "ses_Parent", ses_Nested: "ses_Child", ses_ToolFirst: "ses_Parent" }[path.id]
    return { data: { id: path.id, title: "同一标题", parentID } }
  },
} } })
const event = (type, properties) => hook.event({ event: { type, properties } })
const chat = (sid, id = "msg_User") => hook["chat.message"]({ sessionID: sid }, { message: { id } })
const tool = sid => hook["tool.execute.before"]({ sessionID: sid, tool: "task", callID: "call_task" }, { args: {} })
const frames = () => existsSync(process.env.AGENTPET_CAPTURE)
  ? readFileSync(process.env.AGENTPET_CAPTURE, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []
const wait = async predicate => {
  const until = Date.now() + 6000
  while (!predicate()) { assert.ok(Date.now() < until, "fixture delivery timed out"); await new Promise(r => setTimeout(r, 20)) }
}
await chat("ses_Parent")
await tool("ses_Parent")
for (const sid of ["ses_Child", "ses_Nested"]) {
  await chat(sid); await tool(sid)
  await event("permission.asked", { sessionID: sid, id: "perm_child" })
  await event("message.updated", { info: { sessionID: sid, id: "msg_Assistant", role: "assistant", parentID: "msg_User" } })
  await event("session.idle", { sessionID: sid })
}
await tool("ses_ToolFirst") // Classification before session.created/chat.message.
await event("session.created", { info: { id: "ses_EventFirst", parentID: "ses_Parent", title: "子任务" } })
for (let i = 0; i < 4; i++)
  await event("session.updated", { info: { id: "ses_EventFirst", parentID: "ses_Parent", title: "子任务" } })
await chat("ses_EventFirst")
await event("session.updated", { info: { id: "ses_EventFirst", title: "partial update cannot erase parent" } })
await chat("ses_EventFirst", "msg_Late")
assert.equal(queries.get("ses_EventFirst"), undefined)
for (const sid of ["ses_Unavailable", "ses_WrongID", "ses_Self"]) {
  await chat(sid); await tool(sid)
}
const race = chat("ses_Race")
await wait(() => releases.has("ses_Race"))
await event("session.created", { info: { id: "ses_Race", parentID: "ses_Parent" } })
releases.get("ses_Race")({ data: { id: "ses_Race", title: "stale root-shaped response" } })
await race
await chat("ses_Unavailable") // Bounded failure cooldown; no new request.
assert.equal(queries.get("ses_Unavailable"), 1)
await event("session.updated", { info: { id: "ses_Unavailable", title: "恢复" } })
await chat("ses_Unavailable", "msg_Recovered")
await event("session.idle", { sessionID: "ses_Unavailable" })
await chat("ses_Independent")
await event("message.updated", { info: { sessionID: "ses_Independent", id: "msg_Assistant", role: "assistant", parentID: "msg_User" } })
await event("session.idle", { sessionID: "ses_Independent" })
await event("session.idle", { sessionID: "ses_Parent" })
await wait(() => frames().some(f => f.session_id === "ses_Parent" && f.event === "done"))
const all = frames()
for (const sid of ["ses_Child", "ses_Nested", "ses_ToolFirst", "ses_EventFirst", "ses_Race"]) {
  const own = all.filter(f => f.session_id === sid)
  assert.ok(own.length > 0)
  assert.ok(own.every(f => f.event === "metadata" && f.parent_session_id?.startsWith("ses_")), sid)
}
for (const sid of ["ses_WrongID", "ses_Self"]) assert.equal(all.filter(f => f.session_id === sid).length, 0)
assert.equal(all.filter(f => f.session_id === "ses_Parent" && f.event === "done").length, 1)
assert.equal(all.filter(f => f.session_id === "ses_Parent" && f.new_turn).length, 1)
assert.ok(all.some(f => f.session_id === "ses_Parent" && f.tool === "task"))
assert.ok(all.some(f => f.session_id === "ses_Independent" && f.event === "done"))
assert.ok(all.some(f => f.session_id === "ses_Unavailable" && f.turn_id === "msg_Recovered" && f.event === "done"))
assert.equal(queries.get("ses_Child"), 1)
await Promise.all(Array.from({ length: 16 }, (_, n) => chat(`ses_Lookup${n}`)))
assert.equal([...queries.keys()].filter(id => id.startsWith("ses_Lookup")).length, 8)
assert.ok(!frames().some(f => f.session_id.startsWith("ses_Lookup")))
console.log("PASS: exact native parent classification, nested/tool-first children, SDK race, bounded fail-closed recovery and independent roots")
