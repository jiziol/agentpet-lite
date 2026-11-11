import Foundation

/// Uses the event and tool callbacks shipped with official opencode 1.18.34.
public enum OpencodePlugin {
    public static func isOwned(_ source: String) -> Bool {
        func literal(_ name: String) -> String? {
            let prefix = "const \(name) = "
            let lines = source.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
            guard lines.count == 1 else { return nil }
            return try? JSONDecoder().decode(String.self, from: Data(lines[0].dropFirst(prefix.count).utf8))
        }
        guard let binary = literal("AGENTPET_BIN"), let socket = literal("SPEECH_SOCKET") else { return false }
        return source == self.source(binary: binary, speechSocketPath: socket)
            || source == self.source(binary: binary, speechSocketPath: socket, legacyLocalDirectory: true)
            || source == OpencodeV2Plugin.source(binary: binary, speechSocketPath: socket)
    }

    public static func source(binary: String, speechSocketPath: String = AgentPetPaths.socketPath,
                              generation: OpencodeVersion.Generation = .v1, legacyLocalDirectory: Bool = false) -> String {
        if generation == .v2 { return OpencodeV2Plugin.source(binary: binary, speechSocketPath: speechSocketPath) }
        let encoded = try! JSONSerialization.data(withJSONObject: [binary])
        let literal = String(data: encoded, encoding: .utf8)!.dropFirst().dropLast()
        let socketData = try! JSONSerialization.data(withJSONObject: [speechSocketPath])
        let socketLiteral = String(data: socketData, encoding: .utf8)!.dropFirst().dropLast()
        return #"""
        // AgentPet integration (auto-generated, safe to delete to uninstall).
        // Observer for official opencode 1.18.34. Does not alter tools or permissions.
        import { spawn } from "node:child_process"
        import { createServer, createConnection } from "node:net"
        import { mkdirSync, chmodSync, unlinkSync, readdirSync, lstatSync } from "node:fs"
        import { homedir } from "node:os"
        import { randomBytes } from "node:crypto"
        const AGENTPET_BIN = \#(literal)
        const SPEECH_SOCKET = \#(socketLiteral)
        export const AgentPet = async (context) => {
          const sessions = new Map()
          const queue = []
          let draining = false, clock = 0, serial = 0, sessionLookups = 0
          const clean = (value, limit = 160) => typeof value === "string"
            ? value.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, limit) : undefined
          const valid = (sid) => typeof sid === "string" && /^ses_[A-Za-z0-9]+$/.test(sid) && sid.length <= 128
          const state = (sid) => {
            if (!valid(sid)) return
            if (!sessions.has(sid)) {
              if (sessions.size >= 256) { const oldest = sessions.keys().next().value; clearSpeech(oldest); sessions.delete(oldest) }
              sessions.set(sid, { phase: "unknown", calls: new Set(), waits: new Set() })
            }
            return sessions.get(sid)
          }
          // Text never enters the hook/helper queue: one bounded volatile stream.
          const speech = new Map(), speechPending = new Map()
          let speechRevision = 0, speechSending = false
          const nativeID = (id, prefix) => typeof id === "string" && id.startsWith(prefix)
            && id.length <= 128 && /^[A-Za-z0-9]+$/.test(id.slice(prefix.length))
          const boundedText = (text) => {
            let result = "", bytes = 0
            for (const char of text) {
              const size = Buffer.byteLength(char)
              if (bytes + size > 2048 || result.length + char.length > 640) break
              result += char; bytes += size
            }
            return result
          }
          const clearSpeech = (sid) => {
            speech.delete(sid)
            for (const [key, frame] of speechPending) if (frame.session_id === sid) speechPending.delete(key)
          }
          const speechState = (sid) => {
            const s = sessions.get(sid)
            if (!s || !nativeID(s.turn, "msg_")) return
            if (!speech.has(sid)) {
              if (speech.size >= 128) clearSpeech(speech.keys().next().value)
              speech.set(sid, { messages: new Map(), parts: new Map(), removedParts: new Set(), removedMessages: new Set() })
            }
            return speech.get(sid)?.blocked ? undefined : speech.get(sid)
          }
          const sendText = (sid, part, mode, text, observed) => {
            const s = sessions.get(sid), st = speech.get(sid), info = st?.messages.get(part.messageID)
            if (!s || !info || info.role !== "assistant" || info.parentID !== s.turn || s.result === "cancelled") return
            const key = sid + ":" + part.id
            if (!speechPending.has(key) && speechPending.size >= 128) return
            speechPending.set(key, { schema: "agentpet.opencode.speech.v1", session_id: sid,
              parent_id: s.turn, message_id: part.messageID, part_id: part.id, process_id: process.pid,
              revision: ++speechRevision, timestamp: observed, mode, text,
              role: "assistant", part_type: "text", synthetic: false, ignored: false })
          }
          const publishPart = (sid, entry) => {
            const s = sessions.get(sid), st = speech.get(sid), info = st?.messages.get(entry.part.messageID)
            if (!info || info.role !== "assistant" || info.parentID !== s?.turn) return
            if (Date.now() / 1000 - entry.observed >= 3) return
            const hidden = entry.part.synthetic === true || entry.part.ignored === true
            if (hidden) {
              if (entry.sent) sendText(sid, entry.part, "withdraw", "", entry.observed)
              entry.sent = false; entry.text = ""; return
            }
            if (entry.sentText === entry.text) return
            sendText(sid, entry.part, "snapshot", entry.text, entry.observed)
            entry.sent = true; entry.sentText = entry.text
          }
          const observeMessage = (sid, info) => {
            const st = speechState(sid)
            if (!st || !nativeID(info?.id, "msg_") || st.removedMessages.has(info.id)) return
            if (!st.messages.has(info.id) && st.messages.size >= 16) st.messages.delete(st.messages.keys().next().value)
            st.messages.set(info.id, { role: info.role, parentID: info.parentID })
            if (info.role === "assistant" && info.parentID === sessions.get(sid)?.turn) {
              for (const entry of st.parts.values()) if (entry.part.messageID === info.id) publishPart(sid, entry)
            }
          }
          const observePart = (sid, part) => {
            const st = speechState(sid)
            // 1.18.34 text is a full snapshot even when properties.delta is present.
            // Reject delta-only shapes rather than append the same suffix twice.
            if (!st || part?.type !== "text" || typeof part.text !== "string"
                || !nativeID(part.id, "prt_") || !nativeID(part.messageID, "msg_")
                || st.removedParts.has(part.id) || st.removedMessages.has(part.messageID)) return
            const info = st.messages.get(part.messageID), s = sessions.get(sid)
            if (info && (info.role !== "assistant" || info.parentID !== s.turn)) return
            if (!st.parts.has(part.id) && st.parts.size >= 4) st.parts.delete(st.parts.keys().next().value)
            const old = st.parts.get(part.id)
            const entry = { part: { id: part.id, messageID: part.messageID, synthetic: part.synthetic, ignored: part.ignored },
              text: boundedText(part.text), observed: Math.max(Date.now() / 1000, clock),
              sent: old?.sent || false, sentText: old?.sentText }
            st.parts.set(part.id, entry); publishPart(sid, entry)
          }
          const removePart = (sid, partID, messageID) => {
            const st = speech.get(sid)
            if (!st) return
            const tombstones = partID ? st.removedParts : st.removedMessages
            const removed = partID || messageID
            if (!nativeID(removed, partID ? "prt_" : "msg_")) return
            // Saturation drops this source's text state, never resurrects removed history.
            if (tombstones.size >= 16 && !tombstones.has(removed)) {
              st.blocked = true; st.messages.clear(); st.parts.clear()
              for (const [key, frame] of speechPending) if (frame.session_id === sid) speechPending.delete(key)
              return
            }
            tombstones.add(removed)
            for (const [id, entry] of st.parts) {
              if ((partID && id !== partID) || (messageID && entry.part.messageID !== messageID)) continue
              if (entry.sent) sendText(sid, entry.part, "withdraw", "", Math.max(Date.now() / 1000, clock))
              st.parts.delete(id)
            }
          }
          const speechTimer = setInterval(() => {
            if (speechSending || !speechPending.size) return
            const frames = []
            for (const [key, frame] of speechPending) {
              speechPending.delete(key)
              if (Date.now() / 1000 - frame.timestamp < 3 && sessions.get(frame.session_id)?.turn === frame.parent_id
                  && sessions.get(frame.session_id)?.result !== "cancelled") frames.push(frame)
              if (frames.length >= 32) break
            }
            if (!frames.length) return
            speechSending = true
            let socket
            try {
              socket = createConnection(SPEECH_SOCKET)
              socket.on("error", () => {})
              socket.on("close", () => { speechSending = false })
              socket.setTimeout(500, () => socket.destroy())
              socket.on("connect", () => socket.end(frames.map((frame) => JSON.stringify(frame) + "\n").join("")))
            } catch { speechSending = false; socket?.destroy() }
            // Failed delivery is dropped. No offline replay or disk fallback.
          }, 500)
          speechTimer.unref()
          process.once("exit", () => clearInterval(speechTimer))
          const drain = async () => {
            if (draining) return
            draining = true
            try {
              while (queue.length) {
                const frame = queue.shift()
                await new Promise((resolve) => {
                  let timer, child, ended = false
                  const finish = () => { if (!ended) { ended = true; clearTimeout(timer); resolve() } }
                  try {
                    child = spawn(AGENTPET_BIN, ["hook", "--agent", "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
                    child.on("error", finish)
                    child.on("close", finish)
                    child.stdin.on("error", () => {})
                    child.stdin.end(JSON.stringify(frame))
                    timer = setTimeout(() => { child.kill("SIGKILL"); finish() }, 2000)
                  } catch { finish() }
                })
              }
            } finally { draining = false }
          }
          const emit = (sid, event, extra = {}) => {
            const s = state(sid); if (!s) return
            if (s.scope !== "root" && !(s.scope === "child" && event === "metadata")) return
            const frame = { version: 1, session_id: sid, event,
              project: clean(context.directory, 4096), title: s.title, model: s.model,
              parent_session_id: s.parentSessionID,
              turn_id: s.turn, navigation_socket: navigationSocket, process_id: process.pid, ...extra }
            // Streaming duplicates never create new receipts or helper processes.
            const key = JSON.stringify(frame)
            if (event !== "heartbeat" && s.last === key) return
            // Bounded delivery; terminal/attention events displace routine work first.
            if (queue.length >= 256) {
              const index = queue.findIndex((f) => !f.agentpet_human && ["working", "metadata", "heartbeat"].includes(f.event))
              if (index < 0) return
              queue.splice(index, 1)
            }
            if (event !== "heartbeat") s.last = key
            clock = Math.max(Date.now() / 1000, clock + 0.001)
            queue.push({ ...frame, timestamp: clock })
            void drain()
          }
          const metadata = (sid, info) => {
            const s = state(sid); if (!s || !info) return
            const title = clean(info.title)
            const model = clean(info.modelID || info.model?.modelID)
            if (title) s.title = title
            if (model) s.model = model
            emit(sid, "metadata")
          }
          // Session.parentID is the only subagent evidence. Assistant.parentID
          // identifies a user message and must never classify a session.
          const classify = (sid, info) => {
            const s = state(sid)
            if (!s || info?.id !== sid) return false
            if (info.parentID != null && (!valid(info.parentID) || info.parentID === sid)) return false
            if (s.parentSessionID && info.parentID !== s.parentSessionID) return false
            s.scope = info.parentID ? "child" : "root"
            s.parentSessionID = info.parentID || undefined
            if (s.scope === "child") {
              clearSpeech(sid)
              for (let i = queue.length - 1; i >= 0; --i)
                if (queue[i].session_id === sid && queue[i].parent_session_id !== s.parentSessionID) queue.splice(i, 1)
              s.phase = "unknown"; s.calls.clear(); s.waits.clear()
            }
            metadata(sid, info)
            return true
          }
          const rootSession = async (sid) => {
            const s = state(sid); if (!s) return false
            if (s.scope) return s.scope === "root"
            if (!s.lookup && Date.now() >= (s.retryAt || 0)) {
              if (sessionLookups >= 8) return false
              sessionLookups++
              s.lookup = (async () => {
                let timer
                try {
                  const result = await Promise.race([
                    Promise.resolve().then(() => context.client.session.get({ path: { id: sid }, signal: AbortSignal.timeout(800) })),
                    new Promise((resolve) => { timer = setTimeout(() => resolve(null), 800) }),
                  ])
                  if (sessions.get(sid) === s && !s.scope) classify(sid, result?.data)
                } catch {} finally { clearTimeout(timer); sessionLookups--; s.retryAt = Date.now() + 500 }
              })().finally(() => { s.lookup = undefined })
            }
            await s.lookup
            return sessions.get(sid) === s && s.scope === "root"
          }
          const begin = (sid, turn, model) => {
            const s = state(sid); if (!s || s.scope !== "root") return
            const newTurn = !!(turn && s.turn !== turn || s.phase === "unknown" || s.phase === "done")
            if (newTurn) {
              clearSpeech(sid)
              s.turn = turn || `turn:${process.pid}:${++serial}`
              s.result = undefined; s.calls.clear(); s.waits.clear()
              s.activity = undefined
            }
            if (model) s.model = clean(model)
            s.phase = "working"
            emit(sid, "working", { new_turn: newTurn })
          }
          // The default TUI uses an in-process server. Keep navigation in the
          // owning plugin and publish through its already authenticated SDK.
          let navigationSocket
          if (!process.argv.some((arg) => ["run", "serve", "web", "acp"].includes(arg))) {
            try {
              const folder = \#(legacyLocalDirectory ? "homedir() + \"/.agentpet-local\"" : "SPEECH_SOCKET.slice(0, SPEECH_SOCKET.lastIndexOf(\"/\"))")
              mkdirSync(folder, { recursive: true, mode: 0o700 })
              // A terminated Bun TUI worker may not execute process.exit hooks.
              // Remove only this observer's sockets whose owning process is gone.
              for (const name of readdirSync(folder).filter((n) => /^oc-[0-9]+-[a-f0-9]{16}\.sock$/.test(n)).slice(0, 256)) {
                const pid = Number(name.split("-")[1])
                try { process.kill(pid, 0) } catch (error) {
                  if (error.code === "ESRCH") {
                    try {
                      const old = folder + "/" + name, info = lstatSync(old)
                      if (info.isSocket() && info.uid === process.getuid()) unlinkSync(old)
                    } catch {}
                  }
                }
              }
              const path = `${folder}/oc-${process.pid}-${randomBytes(8).toString("hex")}.sock`
              let connections = 0
              const bridge = createServer((socket) => {
                if (++connections > 4) { --connections; socket.destroy(); return }
                socket.on("close", () => --connections)
                socket.on("error", () => {})
                socket.setTimeout(2000, () => socket.destroy())
                let bytes = "", answered = false
                socket.on("data", (chunk) => {
                  bytes += chunk.toString()
                  if (bytes.length > 1024) { socket.destroy(); return }
                  if (answered || !bytes.includes("\n")) return
                  answered = true
                  void (async () => {
                    let sid, ok = false
                    try {
                      sid = JSON.parse(bytes.split("\n")[0]).sessionID
                      if (valid(sid) && sessions.has(sid)) {
                        const signal = AbortSignal.timeout(1500)
                        const found = await context.client.session.get({ path: { id: sid }, signal })
                        if (found?.data?.id === sid) {
                          const result = await context.client.tui.publish({ signal, query: { directory: context.directory }, body: {
                            type: "tui.session.select", properties: { sessionID: sid },
                          } })
                          ok = result?.data === true
                        }
                      }
                    } catch {}
                    socket.end(JSON.stringify({ sessionID: sid, ok }) + "\n")
                  })()
                })
              })
              bridge.on("error", () => { navigationSocket = undefined })
              bridge.listen(path, () => { chmodSync(path, 0o600); navigationSocket = path })
              bridge.unref()
              process.once("exit", () => { try { unlinkSync(path) } catch {} })
            } catch {}
          }
          const done = (sid) => {
            const s = state(sid)
            if (!s || s.phase === "unknown" || s.phase === "done") return
            s.phase = "done"; s.waits.clear()
            emit(sid, "done", { result: s.result || "completed" })
          }
          // Long tools and inference can be silent for minutes. A single native
          // status query per plugin keeps them alive without inventing activity,
          // changing receipts, or waking a helper for every streamed token.
          let checkingStatus = false
          const livenessTimer = setInterval(() => {
            if (checkingStatus || ![...sessions.values()].some((s) => ["working", "waiting"].includes(s.phase))) return
            checkingStatus = true
            const observed = [...sessions].filter(([, s]) => ["working", "waiting"].includes(s.phase))
              .map(([sid, s]) => ({ sid, session: s, turn: s.turn }))
            void Promise.resolve().then(() => context.client.session.status({
              query: { directory: context.directory }, signal: AbortSignal.timeout(1500),
            })).then((result) => {
              const statuses = result?.data
              if (!statuses || typeof statuses !== "object" || Array.isArray(statuses)) return
              for (const { sid, session: s, turn } of observed) {
                if (sessions.get(sid) !== s || s.turn !== turn || !["working", "waiting"].includes(s.phase)) continue
                const native = statuses[sid]
                if (["busy", "retry"].includes(native?.type)) emit(sid, "heartbeat")
                else if (native?.type === "idle" || !(sid in statuses)) done(sid)
              }
            }).catch(() => {}).finally(() => { checkingStatus = false })
          }, 30000)
          livenessTimer.unref()
          process.once("exit", () => clearInterval(livenessTimer))
          const tool = (sid, name, args, call) => {
            const s = state(sid); if (!s || s.phase === "done") return
            if (call && s.calls.has(call)) return
            if (call) { if (s.calls.size >= 128) s.calls.clear(); s.calls.add(call) }
            if (s.phase === "unknown") begin(sid)
            // Never transmit command arguments, contents, prompts or tool output.
            const path = args?.filePath || args?.file_path || args?.path
            const input = {}
            if (typeof path === "string") input.file_path = clean(path.split(/[\\/]/).pop(), 80)
            if (typeof args?.command === "string") {
              const executable = args.command.trim().split(/\s+/)[0].split("/").pop()
              if (["git", "rg", "grep", "find", "cat", "head", "tail", "sed", "python", "python3", "swift", "swiftc"].includes(executable))
                input.cmd = executable
            }
            s.activity = { tool: clean(name, 64), tool_input: input, activity_id: clean(call, 128) }
            // A parallel tool must not erase another outstanding native request.
            if (s.waits.size) return
            s.phase = "working"
            emit(sid, "working", s.activity)
          }
          return {
            "chat.message": async (input, output) => {
              if (await rootSession(input.sessionID))
                begin(input.sessionID, output?.message?.id || input.messageID, input.model?.modelID)
            },
            "tool.execute.before": async (input, output) => {
              if (await rootSession(input.sessionID)) tool(input.sessionID, input.tool, output?.args, input.callID)
            },
            event: async ({ event }) => {
              const p = event?.properties || {}
              const sid = p.sessionID || p.info?.sessionID || p.part?.sessionID || p.info?.id
              if (!valid(sid)) return
              const s = state(sid)
              if (["session.created", "session.updated"].includes(event.type)) { classify(sid, p.info); return }
              if (!(await rootSession(sid))) {
                if (event.type === "session.deleted") { clearSpeech(sid); sessions.delete(sid) }
                return
              }
              switch (event.type) {
              case "session.deleted": emit(sid, "deleted"); clearSpeech(sid); sessions.delete(sid); break
              case "message.updated":
                observeMessage(sid, p.info)
                if (p.info?.role === "assistant") {
                  metadata(sid, p.info)
                  if (p.info.error) s.result = p.info.error.name === "MessageAbortedError" ? "cancelled" : "failed"
                }
                break
              case "message.removed": removePart(sid, undefined, p.messageID); speech.get(sid)?.messages.delete(p.messageID); break
              case "message.part.removed": removePart(sid, p.partID, p.messageID); break
              case "message.part.updated":
                observePart(sid, p.part)
                if (p.part?.type === "tool" && p.part.state?.status === "running")
                  tool(sid, p.part.tool, p.part.state.input, p.part.callID)
                break
              case "session.status":
                if (["busy", "retry"].includes(p.status?.type)) {
                  if (s.phase === "unknown" || s.phase === "done") begin(sid)
                } else if (p.status?.type === "idle") done(sid)
                break
              case "session.idle": done(sid); break
              case "session.error":
                // Errors can precede idle; a recoverable overflow is not a final failure.
                if (p.error?.name !== "ContextOverflowError")
                  s.result = p.error?.name === "MessageAbortedError" ? "cancelled" : "failed"
                break
              case "permission.asked": case "question.asked":
                if (s.phase === "done") break
                if (s.phase === "unknown") begin(sid)
                if (typeof p.id !== "string" || !p.id.length || p.id.length > 320 || /[\u0000-\u001f\u007f]/.test(p.id) || s.waits.has(p.id) || s.waits.size >= 64) break
                s.phase = "waiting"; s.waits.add(p.id)
                emit(sid, "waiting", { waiting_kind: event.type.startsWith("question.") ? "question" : "permission",
                  agentpet_human: { action: "asked", kind: event.type.startsWith("question.") ? "choice" : "permission", request_ids: [p.id] } })
                break
              case "permission.replied": case "question.replied": case "question.rejected":
                if (!s.waits.delete(p.requestID || p.id)) break
                emit(sid, "working", { agentpet_human: { action: "resolved", request_ids: [p.requestID || p.id] } })
                if (s.phase === "waiting" && !s.waits.size) { s.phase = "working"; emit(sid, "working", s.activity) }
                break
              }
            },
          }
        }
        """#
    }
}
