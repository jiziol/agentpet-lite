import assert from "node:assert/strict"
import { writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs"
import { pathToFileURL } from "node:url"
import { connect } from "node:net"
import os from "node:os"
import { syncBuiltinESMExports } from "node:module"
const root = process.argv[2]
assert.ok(process.env.CFFIXED_USER_HOME, "Run through test-opencode-core.sh for home isolation")
os.homedir = () => process.env.CFFIXED_USER_HOME
syncBuiltinESMExports()
const capture = root + "/frames.jsonl"
process.env.AGENTPET_CAPTURE = capture
writeFileSync(root + "/capture", `#!/usr/bin/env node
let data = "";
process.stdin.on("data", c => data += c);
process.stdin.on("end", () => { require("node:fs").appendFileSync(process.env.AGENTPET_CAPTURE, data + "\\n") });
`)
chmodSync(root + "/capture", 0o700)
const { AgentPet } = await import(pathToFileURL(root + "/agentpet.mjs"))
const published = []
const statusQueries = []
let nativeStatuses = {}
let statusResponse = async () => ({ data: nativeStatuses })
const timers = [], originalInterval = globalThis.setInterval
globalThis.setInterval = (callback, ...args) => { if (args[0] === 30000) timers.push(callback); return originalInterval(callback, ...args) }
const hook = await AgentPet({ directory: "/synthetic/project", client: {
  session: { get: async ({ path }) => ({ data: { id: path.id, title: "Native title" } }),
    status: async (options) => { statusQueries.push(options); return statusResponse() } },
  tui: { publish: async ({ body }) => { published.push(body); return { data: true } } },
} })
globalThis.setInterval = originalInterval
const event = async (type, properties) => hook.event({ event: { type, properties } })
const sid = "ses_pluginABC"
await event("session.created", { info: { id: sid, title: "Native title" } })
await hook["chat.message"]({ sessionID: sid, model: { modelID: "native-model" } }, { message: { id: "msg_1" } })
await hook["tool.execute.before"]({ sessionID: sid, tool: "read", callID: "call_1" }, { args: { filePath: "/private/path/README.md", content: "SECRET" } })
for (let n = 0; n < 50; n++) await event("message.part.updated", { part: { type: "tool", sessionID: sid, tool: "read", callID: "call_1", state: { status: "running", input: { filePath: "/private/path/README.md" } } } })
await event("permission.asked", { sessionID: sid, id: "perm_1", patterns: ["SECRET"] })
await event("question.asked", { sessionID: sid, id: "question_1", questions: ["SECRET"] })
await hook["tool.execute.before"]({ sessionID: sid, tool: "edit", callID: "parallel" }, { args: { filePath: "/private/parallel.txt" } })
await event("permission.replied", { sessionID: sid, requestID: "perm_1" })
await event("question.replied", { sessionID: sid, requestID: "question_1" })
await event("session.error", { sessionID: sid, error: { name: "MessageAbortedError", data: { message: "SECRET" } } })
await event("session.status", { sessionID: sid, status: { type: "idle" } })
await event("session.idle", { sessionID: sid })
await hook["tool.execute.before"]({ sessionID: sid, tool: "bash", callID: "late" }, { args: { command: "curl SECRET" } })
const frames = () => existsSync(capture) ? readFileSync(capture, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []
async function waitFor(predicate) {
  const until = Date.now() + 5000
  while (!predicate()) { if (Date.now() >= until) throw new Error("delivery timeout"); await new Promise(r => setTimeout(r, 20)) }
}
await waitFor(() => frames().some(f => f.event === "done"))
let all = frames()
assert.equal(all.filter(f => f.event === "done").length, 1)
assert.equal(all.at(-1).result, "cancelled")
assert.equal(all.filter(f => f.tool === "read").length, 1)
assert.equal(all.filter(f => f.tool === "bash").length, 0)
assert.equal(all.find(f => f.tool === "read").tool_input.file_path, "README.md")
assert.ok(!JSON.stringify(all).includes("SECRET"))
assert.ok(all.every((f, i) => i === 0 || f.timestamp > all[i - 1].timestamp))
assert.ok(all.some(f => f.event === "waiting") && all.some(f => f.model === "native-model"))
const firstWait = all.findIndex(f => f.event === "waiting")
const resumed = all.findIndex((f, i) => i > firstWait && f.event === "working" && !f.agentpet_human)
assert.equal(all[resumed].tool, "edit", "parallel tool only resumes after all requests replied")
assert.equal(all.slice(firstWait, resumed).filter(f => f.event === "waiting").length, 2)
assert.equal(all.slice(firstWait, resumed).filter(f => f.agentpet_human?.action === "resolved").length, 2)
assert.ok(all.filter(f => f.agentpet_human).every(f => f.agentpet_human.request_ids.length === 1))
await hook["chat.message"]({ sessionID: sid }, { message: { id: "msg_2" } })
await hook["tool.execute.before"]({ sessionID: sid, tool: "bash", callID: "call_2" }, { args: { command: "git status --SECRET" } })
await event("session.error", { sessionID: sid, error: { name: "APIError", data: { message: "SECRET" } } })
await event("session.idle", { sessionID: sid })
await event("session.status", { sessionID: "ses_secondABC", status: { type: "busy" } })
await event("session.idle", { sessionID: "ses_secondABC" })
await waitFor(() => frames().some(f => f.session_id === "ses_secondABC" && f.event === "done"))
all = frames()
assert.equal(all.find(f => f.turn_id === "msg_2" && f.event === "done").result, "failed")
assert.equal(all.find(f => f.session_id === "ses_secondABC" && f.event === "done").result, "completed")
assert.equal(all.find(f => f.tool === "bash").tool_input.cmd, "git")
const path = all.find(f => f.navigation_socket)?.navigation_socket
assert.ok(path)
const socketLine = readFileSync(root + "/agentpet.mjs", "utf8").split("\n").find(line => line.startsWith("const SPEECH_SOCKET = "))
assert.ok(socketLine)
const configuredSocket = JSON.parse(socketLine.slice("const SPEECH_SOCKET = ".length))
assert.equal(path.slice(0, path.lastIndexOf("/")), configuredSocket.slice(0, configuredSocket.lastIndexOf("/")),
  "navigation must use the configured speech socket root")
assert.match(path.slice(path.lastIndexOf("/") + 1), /^oc-[0-9]+-[a-f0-9]{16}\.sock$/)
const response = await new Promise((resolve, reject) => {
  const socket = connect(path); let bytes = ""
  socket.on("error", reject)
  socket.on("connect", () => socket.write(JSON.stringify({ sessionID: sid }) + "\n"))
  socket.on("data", c => { bytes += c; if (bytes.includes("\n")) { socket.end(); resolve(JSON.parse(bytes)) } })
})
assert.equal(response.ok, true)
assert.deepEqual(published, [{ type: "tui.session.select", properties: { sessionID: sid } }])
const live = "ses_livenessABC"
await hook["chat.message"]({ sessionID: live }, { message: { id: "msg_live" } })
nativeStatuses = { [live]: { type: "busy" } }
timers[0]()
await waitFor(() => frames().some(f => f.session_id === live && f.event === "heartbeat"))
timers[0]()
await waitFor(() => frames().filter(f => f.session_id === live && f.event === "heartbeat").length === 2)
assert.ok(frames().filter(f => f.event === "heartbeat").every(f => f.process_id === process.pid))
assert.ok(statusQueries.every(q => q.query.directory === "/synthetic/project" && q.signal instanceof AbortSignal))
nativeStatuses = {}
timers[0]()
await waitFor(() => frames().some(f => f.session_id === live && f.event === "done"))
assert.equal(frames().find(f => f.session_id === live && f.event === "done").result, "completed")
const race = "ses_statusRaceABC"
await hook["chat.message"]({ sessionID: race }, { message: { id: "msg_old" } })
let release
statusResponse = () => new Promise(resolve => { release = resolve })
timers[0]()
await waitFor(() => release)
await hook["chat.message"]({ sessionID: race }, { message: { id: "msg_new" } })
release({ data: {} })
await new Promise(r => setTimeout(r, 100))
assert.ok(!frames().some(f => f.session_id === race && f.event === "done"), "old status response cannot end a new turn")
console.log("PASS: opencode plugin lifecycle, parallel waiting, native liveness, dedup, privacy and navigation bridge")
