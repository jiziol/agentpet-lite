import Foundation

/// Independent observer for the public OpenCode 2.0.29 plugin/event API.
/// No V1 hook names are registered with V2 and no model/tool inputs are changed.
enum OpencodeV2Plugin {
    static func source(binary: String, speechSocketPath: String) -> String {
        func literal(_ value: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [value])
            return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
        }
        return #"""
        // AgentPet integration (auto-generated, safe to delete to uninstall).
        // OpenCode V2 observer. V1 and V2 plugin APIs are incompatible.
        import { spawn } from "node:child_process"
        import { createConnection } from "node:net"
        const AGENTPET_BIN = \#(literal(binary))
        const SPEECH_SOCKET = \#(literal(speechSocketPath))
        // Plugin.define is an identity function in @opencode/plugin 2.0.29.
        // A plain definition avoids installing an SDK into the user's config.
        export default {
          id: "agentpet-lite.observer.v2",
          async setup(ctx) {
            const rows = new Map(), queue = [], children = new Set(), sockets = new Set()
            const controller = new AbortController()
            let active = true, clock = 0, draining, checking = false, revision = 0
            const valid = sid => typeof sid === "string" && /^ses_[A-Za-z0-9]{1,124}$/.test(sid)
            const messageID = id => typeof id === "string" && /^msg_[A-Za-z0-9]{1,124}$/.test(id)
            const clean = (value, limit = 160) => typeof value === "string"
              ? value.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, limit) : undefined
            const boundedText = text => {
              let result = "", bytes = 0
              for (const char of text) {
                const size = Buffer.byteLength(char)
                if (bytes + size > 2048 || result.length + char.length > 640) break
                result += char; bytes += size
              }
              return result
            }
            const drain = () => {
              if (draining) return draining
              draining = (async () => {
                while (queue.length) {
                  const frame = queue.shift()
                  await new Promise(resolve => {
                    let child, timer, ended = false
                    const finish = () => { if (ended) return; ended = true; clearTimeout(timer); children.delete(child); resolve() }
                    try {
                      child = spawn(AGENTPET_BIN, ["hook", "--agent", "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
                      children.add(child); child.on("error", finish); child.on("close", finish)
                      child.stdin.on("error", () => {}); child.stdin.end(JSON.stringify(frame))
                      timer = setTimeout(() => { child.kill("SIGKILL"); finish() }, 2000)
                    } catch { finish() }
                  })
                }
              })().finally(() => { draining = undefined })
              return draining
            }
            const emit = (row, event, extra = {}) => {
              if (!active || row.parentID) return
              const frame = { version: 1, session_id: row.id, event, project: row.project,
                title: row.title, model: row.model, turn_id: row.turn, process_id: process.pid, ...extra }
              const key = JSON.stringify(frame)
              if (event !== "heartbeat" && row.last === key) return
              if (queue.length >= 256) {
                const index = queue.findIndex(f => ["working", "heartbeat", "metadata"].includes(f.event) && !f.agentpet_human)
                if (index < 0) return
                queue.splice(index, 1)
              }
              if (event !== "heartbeat") row.last = key
              clock = Math.max(Date.now() / 1000, clock + 0.001)
              queue.push({ ...frame, timestamp: clock }); void drain()
            }
            const finish = (row, result) => {
              if (!["working", "waiting"].includes(row.phase)) return
              row.phase = "done"; row.waits.clear(); row.messages.clear(); row.parts.clear()
              emit(row, "done", { result })
            }
            // Public Session/Event locations intentionally omit workspaceID.
            const sameLocation = location => location?.directory === ctx.location.directory
            const get = sid => ctx.session.get({ sessionID: sid }, { signal: AbortSignal.timeout(800) })
            let lookups = 0
            const rowFor = async sid => {
              if (!active || !valid(sid)) return
              let row = rows.get(sid)
              if (!row) {
                if (rows.size >= 128) {
                  const old = [...rows].find(([, r]) => r.phase === "done" || r.parentID)
                  if (!old) return
                  rows.delete(old[0])
                }
                row = { id: sid, phase: "unknown", waits: new Set(), messages: new Set(), parts: new Map(), seq: -1 }
                rows.set(sid, row)
              }
              if (row.known) return row
              if (!row.lookup && lookups < 8 && Date.now() >= (row.retryAt || 0)) {
                lookups++
                row.lookup = Promise.resolve().then(() => get(sid)).then(info => {
                  if (!active || rows.get(sid) !== row || info?.id !== sid || !sameLocation(info.location)) return
                  if (info.parentID != null && (!valid(info.parentID) || info.parentID === sid)) return
                  row.known = true; row.parentID = info.parentID
                  row.project = clean(info.location.directory, 4096); row.title = clean(info.title); row.model = clean(info.model?.id)
                  // Child sessions never become separate parent task cards.
                  if (row.parentID) emit(row, "metadata")
                }).catch(() => {}).finally(() => { lookups--; row.lookup = undefined; row.retryAt = Date.now() + 500 })
              }
              await row.lookup
              return row.known && active ? row : undefined
            }
            const begin = (row, turn) => {
              if (!messageID(turn)) return
              if (row.turn === turn && row.phase !== "unknown") return
              row.turn = turn; row.started = Date.now(); row.phase = "working"
              row.waits.clear(); row.messages.clear(); row.parts.clear(); row.activity = undefined
              emit(row, "working", { new_turn: true })
            }
            const tool = (row, name, input, id) => {
              if (!["working", "waiting"].includes(row.phase)) return
              const safe = {}, path = input?.filePath || input?.file_path || input?.path
              if (typeof path === "string") safe.file_path = clean(path.split(/[\\/]/).pop(), 80)
              if (typeof input?.command === "string") {
                const program = input.command.trim().split(/\s+/)[0].split("/").pop()
                if (["git", "rg", "grep", "find", "cat", "head", "tail", "sed", "python", "python3", "swift", "swiftc"].includes(program)) safe.cmd = program
              }
              row.activity = { tool: clean(name, 64), tool_input: safe, activity_id: clean(id, 128) }
              if (!row.waits.size) emit(row, "working", row.activity)
            }
            const speech = (row, data, created) => {
              if (!["working", "waiting"].includes(row.phase) || !row.messages.has(data.assistantMessageID)
                  || !Number.isSafeInteger(data.ordinal) || data.ordinal < 0 || typeof data.text !== "string"
                  || !Number.isFinite(created) || created < row.started - 2000 || Math.abs(Date.now() - created) >= 3000) return
              const part = "prt_" + data.assistantMessageID.slice(4) + "x" + data.ordinal
              if (part.length > 128 || row.parts.has(part) || row.parts.size >= 16) return
              row.parts.set(part, true)
              const text = boundedText(data.text)
              if (!text.trim()) return
              const frame = { schema: "agentpet.opencode.speech.v1", session_id: row.id, parent_id: row.turn,
                message_id: data.assistantMessageID, part_id: part, process_id: process.pid,
                revision: ++revision, timestamp: Date.now() / 1000, mode: "snapshot", text,
                role: "assistant", part_type: "text", synthetic: false, ignored: false }
              if (sockets.size >= 4) return
              const socket = createConnection(SPEECH_SOCKET); sockets.add(socket)
              socket.on("error", () => {}); socket.on("close", () => sockets.delete(socket))
              socket.setTimeout(500, () => socket.destroy())
              socket.on("connect", () => socket.end(JSON.stringify(frame) + "\n"))
            }
            const resolveWait = (row, id) => {
              if (!row.waits.delete(id)) return
              emit(row, "working", { agentpet_human: { action: "resolved", request_ids: [id] } })
              if (!row.waits.size) { row.phase = "working"; emit(row, "working", row.activity) }
            }
            const observe = async event => {
              if (!active || !event || typeof event.type !== "string") return
              // Whitelist before accessing data: no reasoning, raw request,
              // tool-output, prompt or other private payload is inspected.
              const allowed = ["session.execution.started", "session.execution.succeeded", "session.execution.failed",
                "session.execution.interrupted", "session.inbox.delivered", "session.step.started", "session.text.ended",
                "session.renamed", "session.model.selected", "session.deleted", "session.status", "session.idle",
                "permission.asked", "permission.replied", "form.created", "form.replied", "form.cancelled"]
              if (!allowed.includes(event.type)) return
              if (event.location && !sameLocation(event.location)) return
              const data = event.data, sid = data?.sessionID || data?.form?.sessionID
              const row = await rowFor(sid)
              if (!row || row.parentID) return
              const seq = event.durable?.seq
              if (seq !== undefined) {
                if (!Number.isSafeInteger(seq) || seq <= row.seq) return
                row.seq = seq
              }
              if (event.type === "session.execution.started") {
                begin(row, "msg_" + String(event.id).replace(/^evt_/, "")); return
              }
              if (event.type === "session.inbox.delivered") { begin(row, data.inboxID); return }
              if (event.type === "session.deleted") { emit(row, "deleted"); rows.delete(sid); return }
              if (event.type === "session.renamed") { row.title = clean(data.title); emit(row, "metadata"); return }
              if (event.type === "session.model.selected") { row.model = clean(data.model?.id); emit(row, "metadata"); return }
              if (event.type === "session.execution.succeeded") { finish(row, "completed"); return }
              if (event.type === "session.execution.failed") { finish(row, "failed"); return }
              if (event.type === "session.execution.interrupted") { finish(row, data.reason === "user" ? "cancelled" : "unknown"); return }
              if (event.type === "session.status" && ["busy", "retry"].includes(data.status?.type) && row.phase === "unknown")
                begin(row, "msg_" + String(event.id).replace(/^evt_/, ""))
              if (!["working", "waiting"].includes(row.phase)) return
              if (event.type === "session.step.started" && messageID(data.assistantMessageID)) {
                if (row.messages.size >= 16) row.messages.delete(row.messages.values().next().value)
                row.messages.add(data.assistantMessageID); row.model = clean(data.model?.id) || row.model; emit(row, "metadata")
              } else if (event.type === "session.text.ended") speech(row, data, event.created)
              else if (event.type === "permission.asked" || event.type === "form.created") {
                const id = event.type === "form.created" ? data.form?.id : data.id
                if (typeof id !== "string" || !id.length || id.length > 320 || /[\u0000-\u001f\u007f]/.test(id)
                    || row.waits.size >= 64 || row.waits.has(id)) return
                const fields = event.type === "form.created" ? data.form?.fields : undefined
                const kind = fields ? fields.some(f => f.type === "boolean" || f.type === "multiselect" || f.options?.length) ? "choice" : "reply" : "permission"
                row.waits.add(id); row.phase = "waiting"
                emit(row, "waiting", { waiting_kind: kind === "permission" ? "permission" : "question",
                  agentpet_human: { action: "asked", kind, request_ids: [id] } })
              } else if (["permission.replied", "form.replied", "form.cancelled"].includes(event.type)) resolveWait(row, data.requestID || data.id)
            }
            await ctx.tool.hook("execute.before", async event => {
              const row = await rowFor(event.sessionID)
              if (row && !row.parentID) tool(row, event.tool, event.input, event.id)
            })
            const stream = (async () => {
              try {
                for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
                  try { await observe(event) } catch { /* Isolate observer errors from the agent. */ }
                }
              } catch { /* Cancellation and disconnect do not imply success. */ }
              finally { if (active) for (const row of rows.values()) finish(row, "unknown") }
            })()
            const heartbeat = setInterval(() => {
              if (!active || checking) return
              const pending = [...rows.values()].filter(r => ["working", "waiting"].includes(r.phase))
              if (!pending.length) return
              checking = true
              let next = 0
              void Promise.all(Array.from({ length: Math.min(8, pending.length) }, async () => {
                while (next < pending.length && active) {
                  const row = pending[next++], turn = row.turn
                  try {
                    const info = await get(row.id)
                    if (!active || rows.get(row.id) !== row || row.turn !== turn || !["working", "waiting"].includes(row.phase)) continue
                    if (Number.isFinite(info?.time?.idle) && info.time.idle >= row.started && info.outcome)
                      finish(row, info.outcome === "succeeded" ? "completed" : info.outcome === "failed" ? "failed" : "unknown")
                    else emit(row, "heartbeat")
                  } catch { /* No native answer: do not manufacture a heartbeat. */ }
                }
              })).finally(() => { checking = false })
            }, 30000)
            heartbeat.unref()
            return async () => {
              if (!active) return
              for (const row of rows.values()) finish(row, "unknown")
              active = false; clearInterval(heartbeat); controller.abort()
              for (const socket of sockets) socket.destroy()
              let timer
              await Promise.race([draining || Promise.resolve(), new Promise(resolve => { timer = setTimeout(resolve, 2200) })]).finally(() => clearTimeout(timer))
              queue.length = 0
              for (const child of children) child.kill("SIGKILL")
              rows.clear(); void stream
            }
          },
        }
        """#
    }
}
