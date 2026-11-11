import Foundation

/// Optional TUI part for the public OpenCode 2.2.2 navigation API.
/// The existing V2 server observer stays independent and unchanged.
public enum OpencodeTUIPlugin {
    public static let manifest = "{\"name\":\"agentpet-lite-opencode\",\"type\":\"module\",\"exports\":{\".\":\"./index.js\",\"./tui\":\"./tui.js\"}}\n"

    public static func isOwned(_ source: String) -> Bool {
        let prefix = "const SPEECH_SOCKET = "
        let lines = source.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
        guard lines.count == 1, let socket = try? JSONDecoder().decode(String.self, from: Data(lines[0].dropFirst(prefix.count).utf8)) else { return false }
        return source == self.source(speechSocketPath: socket)
    }

    public static func source(speechSocketPath: String) -> String {
        let literal = String(data: try! JSONEncoder().encode(speechSocketPath), encoding: .utf8)!
        return #"""
        // AgentPet TUI navigation (auto-generated; managed with the server part).
        import { createServer } from "node:net"
        import { mkdirSync, lstatSync, chmodSync, writeFileSync, renameSync, unlinkSync, realpathSync } from "node:fs"
        import { dirname, join } from "node:path"
        import { randomBytes } from "node:crypto"
        import { execFileSync } from "node:child_process"
        const SPEECH_SOCKET = \#(literal)
        export default { id: "agentpet-lite.navigation.v2", async setup(ctx) {
          const version = String(ctx.app.version), match = /^(2)\.(\d+)\.(\d+)$/.exec(version)
          if (!match || (+match[2] < 2 || (+match[2] === 2 && +match[3] < 2)) ||
              typeof ctx.ui?.router?.navigate !== "function" || typeof ctx.ui?.router?.current !== "function" ||
              typeof ctx.ui?.tabs?.list !== "function" || typeof ctx.client?.session?.get !== "function") return
          const base = dirname(SPEECH_SOCKET), directory = join(base, "opencode-tui")
          // No real config, transcript, prompt or credentials are read here.
          let tty
          try { tty = execFileSync("/usr/bin/tty", { stdio: ["inherit", "pipe", "ignore"], timeout: 500 }).toString().trim() } catch {}
          if (!/^\/dev\/tty[a-zA-Z0-9]+$/.test(tty || "")) return
          const program = process.env.TERM_PROGRAM
          if (!["iTerm.app", "Apple_Terminal"].includes(program)) return
          let project
          try { project = realpathSync(ctx.location?.directory ?? ctx.data.location.default()?.directory) } catch { return }
          const privateDirectory = path => {
            mkdirSync(path, { recursive: true, mode: 0o700 })
            const stat = lstatSync(path)
            if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw Error("unsafe navigation directory")
          }
          try { privateDirectory(base); privateDirectory(directory) } catch { return }
          const instance = randomBytes(16).toString("hex"), nonce = randomBytes(24).toString("hex")
          const socketPath = join(base, `oc2-${process.pid}-${instance.slice(0,16)}.sock`)
          const recordPath = join(directory, `instance-${process.pid}-${instance.slice(0,16)}.json`)
          if (Buffer.byteLength(socketPath) >= 104) return
          const sessionID = id => typeof id === "string" && /^ses_[A-Za-z0-9]{1,124}$/.test(id)
          const confirmed = new Set()
          const owns = id => {
            const route = ctx.ui.router.current()
            return (route.type === "session" && route.sessionID === id) ||
              ctx.ui.tabs.list().some(tab => tab.sessionID === id) || confirmed.has(id)
          }
          let active = true, busy = false
          const publish = () => {
            const record = { schema: 1, version, pid: process.pid, instance, nonce, socket: socketPath, project, program, tty, updatedAt: Date.now() / 1000 }
            const temp = recordPath + ".tmp"
            writeFileSync(temp, JSON.stringify(record), { mode: 0o600 }); renameSync(temp, recordPath)
          }
          const server = createServer(socket => {
            let data = "", handled = false
            socket.setTimeout(2500, () => socket.destroy()); socket.on("error", () => {})
            socket.on("data", chunk => {
              if (handled) return
              data += chunk
              if (Buffer.byteLength(data) > 4096) { handled = true; socket.destroy(); return }
              if (!data.includes("\n")) return
              handled = true
              const reply = (req, values) => { if (!socket.destroyed) socket.end(JSON.stringify({ sessionID: req?.sessionID, instance, nonce, pid: process.pid, ...values }) + "\n") }
              void (async () => {
                let req
                try {
                  req = JSON.parse(data.split("\n")[0])
                  if (!active || req.nonce !== nonce || req.instance !== instance || !sessionID(req.sessionID) ||
                      !["probe", "select"].includes(req.action) || !Number.isFinite(req.expiresAt) || req.expiresAt < Date.now()/1000 || req.expiresAt > Date.now()/1000 + 5) return reply(req, { ok: false })
                  // Project equality only fences scope. Actual ownership comes
                  // from live tabs or a verified selection, never the global
                  // list or a transient startup route saved as permanent state.
                  if (!owns(req.sessionID)) return reply(req, { ok: false, owns: false })
                  if (req.action === "probe") return reply(req, { ok: true, owns: true })
                  if (busy) return reply(req, { ok: false })
                  busy = true
                  try {
                    const response = await ctx.client.session.get({ sessionID: req.sessionID }, { signal: AbortSignal.timeout(800) })
                    const info = response?.data ?? response
                    if (!info || info.id !== req.sessionID || !active || req.expiresAt < Date.now()/1000) return reply(req, { ok: false })
                    let actual
                    try { actual = realpathSync(info.location?.directory) } catch { return reply(req, { ok: false }) }
                    if (actual !== project) return reply(req, { ok: false })
                    await ctx.data.session.sync(req.sessionID)
                    if (!active || req.expiresAt < Date.now()/1000) return reply(req, { ok: false })
                    ctx.ui.router.navigate({ type: "session", sessionID: req.sessionID })
                    if (ctx.ui.tabs.enabled()) ctx.ui.tabs.focus(req.sessionID)
                    await new Promise(resolve => setTimeout(resolve, 100))
                    const route = ctx.ui.router.current()
                    const ok = active && route.type === "session" && route.sessionID === req.sessionID
                    if (ok) {
                      confirmed.add(req.sessionID)
                      while (confirmed.size > 256) confirmed.delete(confirmed.values().next().value)
                    }
                    reply(req, { ok, route })
                  } finally { busy = false }
                } catch { reply(req, { ok: false }) }
              })()
            })
          })
          server.on("error", () => {})
          try {
            await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, () => { chmodSync(socketPath, 0o600); resolve() }) })
            publish()
          } catch { active = false; server.close(); try { unlinkSync(socketPath) } catch {}; return }
          const timer = setInterval(() => { if (active) try { publish() } catch {} }, 5000)
          timer.unref?.()
          return () => {
            active = false; clearInterval(timer); server.close()
            for (const path of [recordPath, recordPath + ".tmp", socketPath]) try { unlinkSync(path) } catch {}
          }
        }}
        """#
    }
}
