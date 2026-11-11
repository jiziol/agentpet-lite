import AgentPetCore
import Foundation

/// CLI helper invoked by agent hooks: `agentpet hook --event ... --session ...`.
enum HookCLI {
    static func run(arguments: [String]) -> Never {
        // Explicit flags win (used by opencode's plugin and the run wrapper);
        // otherwise fall back to the agent's hook payload on stdin, decoded with
        // that agent's field convention. `--agent` selects the agent.
        let now = Date()
        let parsed = HookArguments.parse(arguments)
        let kind = parsed.agent.map { AgentKind(rawValue: $0) ?? .unknown } ?? .claude
        guard !RetiredAgentRegistry.ignores(kind, rawName: parsed.agent) else {
            FileHandle.standardError.write(Data("AgentPet Lite: retired source ignored\n".utf8))
            exit(0)
        }
        var event = parsed.makeEvent(now: now)
            ?? HookPayload.event(forAgent: kind, stdin: FileHandle.standardInput.readDataToEndOfFile(), now: now)
        if let ao = AOHostEnvironment.capture() {
            event?.aoSessionID = ao.sessionID
            event?.aoProjectID = ao.projectID
            event?.aoLaunchID = ao.launchID
        }

        // This is a monitoring-only Hook. A verified disposable title client
        // must not create a task, notification or usage receipt in the daemon.
        if kind == .codex, CodexHookOrigin.isAionUiTitle() { exit(0) }

        if kind == .antigravity { event?.antigravityFromDSH = AntigravityHostOrigin.isDSH() }
        event?.dshTUI = DSHTUIOrigin.isHosted()

        // Tag the event with the terminal we're running in, so a click on the
        // session's bubble row can focus that exact window/tab later.
        let terminal = TerminalInfo.capture()
        if kind == .unknown { event?.agentName = parsed.agent }
        event?.terminalProgram = terminal.program
        event?.terminalTTY = terminal.tty
        event?.terminalFocusURL = terminal.focusURL
        if kind == .codex { event?.codexHome = CodexMetadata.defaultHome }
        if kind == .opencode, let pid = event?.opencodeProcessID {
            event?.opencodeProcessStartedAt = OpencodeLiveness.processStartedAt(pid)
        }

        guard let event else {
            FileHandle.standardError.write(Data(
                "usage: agentpet hook --event <name> --session <id> [--project <path>] [--agent <kind>] [--message <text>]\n         or pipe a Claude Code hook JSON payload on stdin\n".utf8
            ))
            if kind == .antigravity { print("{}") }
            // Fail OPEN: a monitoring hook must never block the agent. Some agents
            // (e.g. Grok Build) scan ~/.claude / ~/.cursor and feed us a payload we
            // can't decode; exit 2 there would be read as a Stop-gate "keep going"
            // (re-prompt loop) or a PreToolUse "deny". Exit 0 = do nothing, safely.
            exit(0)
        }
        // Approval-gated events must reply with the hook's permission decision on
        // stdout so Claude Code can allow/deny the tool call synchronously.
        if event.approvalRequestId != nil {
            let decision = EventSender.sendAndAwaitReply(event, socketPath: AgentPetPaths.socketPath)
            print(ApprovalHookResponse.json(for: decision))
            exit(0)
        }
        EventSender.send(event, socketPath: AgentPetPaths.socketPath, queueDir: AgentPetPaths.queueDir)
        // Empty protojson means no permission, overwrite, or continuation
        // intervention. A monitor must not approve tools or block stopping.
        if kind == .antigravity { print("{}") }
        exit(0)
    }
}
