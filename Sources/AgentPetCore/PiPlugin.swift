import Foundation

/// Observes Pi's native, aggregate ui_prompt_start/end events. The extension
/// never wraps, answers or changes another extension's UI calls.
public enum PiPlugin {
    /// Exact current generated template with a variable binary path. Modified
    /// or unknown extensions are preserved for manual review, not overwritten.
    public static func isOwned(_ text: String) -> Bool {
        let prefix = "const AGENTPET_BIN = "
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
              let binary = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst(prefix.count).utf8)) else { return false }
        return text == source(binary: binary) || text == previousSettledSource(binary: binary) || text == previousSource(binary: binary) || text == legacySource(binary: binary)
    }

    static func legacySource(binary: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let literal = String(data: try! encoder.encode(binary), encoding: .utf8)!
        return """
        // AgentPet integration (auto-generated, safe to delete to uninstall).
        // Reports Pi session lifecycle to AgentPet's menu bar app.
        import { spawn } from "node:child_process"
        const AGENTPET_BIN = \(literal)
        export default function (pi) {
          const send = (state, ctx) => {
            try {
              const cwd = (ctx && ctx.cwd) || process.cwd()
              const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
                ? ctx.sessionManager.getSessionFile() : null
              const sid = "pi:" + (file || cwd)
              const p = spawn(AGENTPET_BIN, ["hook", "--agent", "pi",
                "--event", state, "--session", sid, "--project", cwd], { stdio: "ignore" })
              if (p && p.unref) p.unref()
            } catch (e) {}
          }
          pi.on("session_start", async (_e, ctx) => send("registered", ctx))
          pi.on("agent_start", async (_e, ctx) => send("working", ctx))
          pi.on("agent_end", async (_e, ctx) => send("done", ctx))
          pi.on("session_shutdown", async (_e, ctx) => send("done", ctx))
        }
        """
    }

    static func previousSource(binary: String) -> String {
        let encoded = try! JSONSerialization.data(withJSONObject: [binary])
        let literal = String(data: encoded, encoding: .utf8)!.dropFirst().dropLast()
        return #"""
        // AgentPet integration (auto-generated, safe to delete to uninstall).
        // Requires Pi native ui_prompt_start/end for human intervention alerts.
        import { spawn } from "node:child_process"
        import { randomUUID } from "node:crypto"
        const AGENTPET_BIN = \#(literal)
        export default function (pi) {
          const epoch = randomUUID(), sessions = new Map(), queue = []
          let serial = 0, draining = false
          const info = (ctx) => {
            const cwd = ctx?.cwd || process.cwd()
            const sid = "pi:" + (ctx?.sessionManager?.getSessionFile?.() || cwd)
            if (!sessions.has(sid)) {
              if (sessions.size >= 128) sessions.delete(sessions.keys().next().value)
              sessions.set(sid, { running: false })
            }
            return { sid, cwd, s: sessions.get(sid) }
          }
          const send = (state, ctx, human) => {
            const { sid, cwd } = info(ctx)
            if (queue.length >= 128) {
              const i = queue.findIndex(f => !f.agentpet_human && f.hook_event_name === "working")
              if (i < 0) return
              queue.splice(i, 1)
            }
            queue.push({ session_id: sid, cwd, hook_event_name: state, agentpet_human: human })
            if (draining) return
            draining = true
            void (async () => {
              try {
                while (queue.length) {
                  const frame = queue.shift()
                  await new Promise(resolve => {
                    let child, timer, ended = false
                    const finish = () => { if (!ended) { ended = true; clearTimeout(timer); resolve() } }
                    try {
                      child = spawn(AGENTPET_BIN, ["hook", "--agent", "pi"], { stdio: ["pipe", "ignore", "ignore"] })
                      child.on("error", finish); child.on("close", finish); child.stdin.on("error", () => {})
                      child.stdin.end(JSON.stringify(frame))
                      timer = setTimeout(() => { child.kill("SIGKILL"); finish() }, 2000)
                    } catch { finish() }
                  })
                }
              } finally { draining = false }
            })()
          }
          const observe = (name, handler) => pi.on(name, async (e, ctx) => { try { handler(e, ctx) } catch {} })
          observe("session_start", (_e, ctx) => send("registered", ctx))
          observe("agent_start", (_e, ctx) => { info(ctx).s.running = true; send("working", ctx) })
          observe("agent_end", (_e, ctx) => { info(ctx).s.running = false; send("done", ctx) })
          observe("ui_prompt_start", (e, ctx) => {
            const { s } = info(ctx)
            if (s.request) return
            s.request = `pi-ui:${epoch}:${++serial}`
            const kind = e.kind === "confirm" ? "permission" : e.kind === "select" ? "choice" : "reply"
            send("waiting", ctx, { action: "asked", kind, request_ids: [s.request] })
          })
          observe("ui_prompt_end", (_e, ctx) => {
            const { s } = info(ctx)
            if (!s.request) return
            send("working", ctx, { action: "resolved", request_ids: [s.request] })
            s.request = undefined
            if (!s.running) send("idle", ctx)
          })
          observe("session_shutdown", (_e, ctx) => { send("session_shutdown", ctx); sessions.delete(info(ctx).sid) })
        }
        """#
    }

    public static func source(binary: String) -> String {
        settledSource(binary: binary, reportsResult: true)
    }

    static func previousSettledSource(binary: String) -> String {
        settledSource(binary: binary, reportsResult: false)
    }

    private static func settledSource(binary: String, reportsResult: Bool) -> String {
        let encoded = try! JSONSerialization.data(withJSONObject: [binary])
        let literal = String(data: encoded, encoding: .utf8)!.dropFirst().dropLast()
        return #"""
        // AgentPet integration (auto-generated, safe to delete to uninstall).
        // Requires Pi >= 0.80.4 (agent_settled) and native ui_prompt_start/end.
        import { spawn } from "node:child_process"
        import { randomUUID } from "node:crypto"
        const AGENTPET_BIN = \#(literal)
        export default function (pi) {
          const epoch = randomUUID(), sessions = new Map(), queue = []
          let serial = 0, draining, activeChild
          const info = (ctx) => {
            const cwd = ctx?.cwd || process.cwd()
            const sid = "pi:" + (ctx?.sessionManager?.getSessionFile?.() || cwd)
            if (!sessions.has(sid)) {
              if (sessions.size >= 128) sessions.delete(sessions.keys().next().value)
              sessions.set(sid, { running: false })
            }
            return { sid, cwd, s: sessions.get(sid) }
          }
          const send = (state, ctx, human, message) => {
            const { sid, cwd } = info(ctx)
            if (queue.length >= 128) {
              const i = queue.findIndex(f => !f.agentpet_human && f.hook_event_name === "working")
              if (i < 0 && state !== "session_shutdown") return draining
              queue.splice(i < 0 ? 0 : i, 1)
            }
            queue.push({ session_id: sid, cwd, hook_event_name: state, agentpet_human: human, message\#(reportsResult ? ", turn_result: state === \"done\" ? \"completed\" : undefined" : "") })
            if (draining) return draining
            draining = (async () => {
              try {
                while (queue.length) {
                  const frame = queue.shift()
                  await new Promise(resolve => {
                    let child, timer, ended = false
                    const finish = () => { if (!ended) { ended = true; clearTimeout(timer); if (activeChild === child) activeChild = undefined; resolve() } }
                    try {
                      child = spawn(AGENTPET_BIN, ["hook", "--agent", "pi"], { stdio: ["pipe", "ignore", "ignore"] })
                      activeChild = child
                      child.on("error", finish); child.on("close", finish); child.stdin.on("error", () => {})
                      child.stdin.end(JSON.stringify(frame))
                      timer = setTimeout(() => { child.kill("SIGKILL"); finish() }, 2000)
                    } catch { finish() }
                  })
                }
              } finally { draining = undefined }
            })()
            return draining
          }
          const observe = (name, handler) => pi.on(name, async (e, ctx) => { try { await handler(e, ctx) } catch {} })
          observe("session_start", (_e, ctx) => { void send("registered", ctx) })
          observe("agent_start", (_e, ctx) => {
            const { s } = info(ctx); s.running = true; s.stopReason = undefined
            void send("working", ctx)
          })
          // agent_end may be followed by retries, compaction or queued work.
          // Only agent_settled is the session-level completion boundary (Pi >= 0.80.4).
          observe("agent_end", (e, ctx) => {
            const last = Array.isArray(e.messages) ? e.messages.findLast(m => m?.role === "assistant") : undefined
            info(ctx).s.stopReason = last?.stopReason
          })
          observe("agent_settled", (e, ctx) => {
            const { s } = info(ctx); s.running = false
            const complete = !e.aborted && ["stop", "length"].includes(s.stopReason)
            const message = e.aborted || s.stopReason === "aborted" ? "任务已停止"
              : s.stopReason === "error" ? "任务结束，发生错误" : undefined
            void send(complete ? "done" : "idle", ctx, undefined, message)
          })
          observe("ui_prompt_start", (e, ctx) => {
            const { s } = info(ctx)
            if (s.request) return
            s.request = `pi-ui:${epoch}:${++serial}`
            const kind = e.kind === "confirm" ? "permission" : e.kind === "select" ? "choice" : "reply"
            send("waiting", ctx, { action: "asked", kind, request_ids: [s.request] })
          })
          observe("ui_prompt_end", (_e, ctx) => {
            const { s } = info(ctx)
            if (!s.request) return
            send("working", ctx, { action: "resolved", request_ids: [s.request] })
            s.request = undefined
            if (!s.running) send("idle", ctx)
          })
          observe("session_shutdown", async (_e, ctx) => {
            const { sid } = info(ctx)
            let timer, flushed = false
            // Pi awaits this handler before process.exit(). Keep normal events
            // asynchronous, but give the final frame a bounded chance to drain.
            try {
              await Promise.race([send("session_shutdown", ctx)?.then(() => { flushed = true }), new Promise(resolve => { timer = setTimeout(resolve, 2500) })])
            } finally {
              clearTimeout(timer)
              if (!flushed) { queue.length = 0; activeChild?.kill("SIGKILL") }
              sessions.delete(sid)
            }
          })
        }
        """#
    }
}
