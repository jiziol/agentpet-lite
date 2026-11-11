// Public TUI context/TTY are fixtures; the production socket and lifecycle run
// unchanged. The separate native 2.2.2 PoC is not replaced by these checks.
import assert from "node:assert/strict"
import { readFileSync, writeFileSync, readdirSync, existsSync, lstatSync } from "node:fs"
import { dirname } from "node:path"
import { createConnection } from "node:net"
import { pathToFileURL } from "node:url"
const [sourcePath, speechSocket] = process.argv.slice(2)
assert.ok(process.env.CFFIXED_USER_HOME, "isolated home required")
const source = readFileSync(sourcePath, "utf8")
const line = 'import { execFileSync } from "node:child_process"'
assert.equal(source.split(line).length, 2)
const fixturePath = sourcePath + ".fixture.mjs"
writeFileSync(fixturePath, source.replace(line, 'const execFileSync = () => Buffer.from("/dev/ttys999\\n")'))
const { default: plugin } = await import(pathToFileURL(fixturePath))
process.env.TERM_PROGRAM = "iTerm.app"
const project = dirname(sourcePath), base = dirname(speechSocket)
const records = () => readdirSync(base + "/opencode-tui").filter(x => x.endsWith(".json")).map(x => JSON.parse(readFileSync(base + "/opencode-tui/" + x, "utf8"))).filter(row => row.pid === process.pid)
let route = { type: "session", sessionID: "ses_A" }, tabs = [{ sessionID: "ses_A" }], reject = false, ignoreRoute = false
let selections = 0, gets = 0
const context = { app: { version: "2.2.2" }, location: { directory: project },
  client: { session: { get: async ({ sessionID }) => { gets++; if (reject) throw Error("not found"); return { data: { id: sessionID, location: { directory: project } } } } } },
  data: { session: { sync: async () => {}, list: () => [{ id: "ses_B" }] } },
  ui: { router: { current: () => route, navigate: r => { selections++; if (!ignoreRoute) route = r } },
    tabs: { list: () => tabs, enabled: () => true, focus: id => { tabs = [{ sessionID: id }] } } }
}
const cleanup = await plugin.setup(context)
assert.equal(typeof cleanup, "function")
const endpoint = records()[0]
assert.equal(lstatSync(endpoint.socket).mode & 0o777, 0o600)
assert.equal(endpoint.tty, "/dev/ttys999")
function call(values) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(endpoint.socket)
    let data = ""
    socket.setTimeout(3000, () => { socket.destroy(); reject(Error("timeout")) })
    socket.on("error", reject)
    socket.on("connect", () => socket.write(JSON.stringify({ action: "probe", sessionID: "ses_A", instance: endpoint.instance, nonce: endpoint.nonce, expiresAt: Date.now()/1000 + 1.5, ...values }) + "\n"))
    socket.on("data", chunk => { data += chunk; if (data.includes("\n")) { socket.destroy(); resolve(JSON.parse(data.split("\n")[0])) } })
  })
}
assert.equal((await call({})).owns, true)
assert.equal((await call({ sessionID: "ses_B" })).owns, false, "A global session list is not ownership")
assert.equal((await call({ nonce: "wrong" })).ok, false)
assert.equal((await call({ expiresAt: 1 })).ok, false)
assert.equal(selections, 0)
route = { type: "session", sessionID: "ses_B" }; tabs = [{ sessionID: "ses_B" }]
assert.equal((await call({ sessionID: "ses_A" })).owns, false, "A transient startup route must not become durable ownership")
route = { type: "session", sessionID: "ses_A" }; tabs = [{ sessionID: "ses_A" }]
assert.equal((await call({ action: "select", sessionID: "ses_A" })).ok, true)
route = { type: "session", sessionID: "ses_B" }; tabs = [{ sessionID: "ses_B" }]
assert.equal((await call({ sessionID: "ses_B" })).owns, true)
assert.equal((await call({ action: "select", sessionID: "ses_A" })).ok, true, "A previously confirmed closed tab can be reopened")
assert.equal(route.sessionID, "ses_A")
route = { type: "session", sessionID: "ses_B" }; tabs = [{ sessionID: "ses_B" }]
assert.equal((await call({ action: "select", sessionID: "ses_B" })).ok, true)
assert.equal((await call({ action: "select", sessionID: "ses_A" })).ok, true)
reject = true
assert.equal((await call({ action: "select", sessionID: "ses_B" })).ok, false)
assert.equal(route.sessionID, "ses_A", "Deleted target cannot change the route")
reject = false; ignoreRoute = true
assert.equal((await call({ action: "select", sessionID: "ses_B" })).ok, false, "Navigation acceptance alone is not a receipt")
assert.ok(gets >= 3)
cleanup()
assert.equal(records().length, 0)
assert.equal(existsSync(endpoint.socket), false)
for (const version of ["2.0.29", "2.1.9", "2.2.1", "3.0.0"]) {
  assert.equal(await plugin.setup({ ...context, app: { version } }), undefined)
  assert.equal(records().length, 0)
}
console.log("PASS: OpenCode TUI ownership, route receipts, version gate, missing targets and socket teardown")
