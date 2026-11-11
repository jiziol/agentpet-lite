# DSH bridge protocol v1

AgentPet is a protocol consumer. The independently maintained `@agentpet-lite/dsh-bridge`
adapter translates DSH APIs into this contract. DSH SDK, adapter release and wire
protocol versions are independent; an adapter version change alone cannot require
an AgentPet update. This document is the contract authority; adapter projects may
vendor a versioned copy of its synthetic conformance fixtures with a checksum.

## Transport and identity

All frames are JSON followed by LF over local Unix sockets. Task events go to the
configured AgentPet event socket. Read-only status/binding and user-initiated navigation
use `/tmp/agentpet-dsh-<uid>/h-<instance>/nav.sock`. The containing directories must be
owned by the current UID with mode 0700 and the socket mode 0600, without symlinks.
AgentPet verifies kernel peer UID/PID; desktop health checks additionally verify
the selected DSH application's process ancestry. This boundary does not defend
against malicious processes running as the same user.

`profileID` is the first 24 lowercase hex digits of SHA256 of the canonical desktop
Profile directory path. `hostID` is a fresh UUID per host generation; `hostStartedAt`
is its Unix start time in seconds. These identities and original session keys must
remain stable across compatible package updates; never reset task/read state to
accommodate a plugin release. Native session IDs are bounded opaque identifiers.

## Task and public-text channels

Existing `agentKind: dsh`, `eventName: dsh/observation` events retain their `dsh.schema: 1`
payload: Profile/Host/session identity, increasing revision/native sequence, optional
turn, phase (`idle`, `working`, `done`), result (`completed`, `cancelled`, `failed`,
`unknown`), pending interaction identities/kinds, timestamps and baseline/heartbeat/gap
flags. History baselines and heartbeats cannot manufacture new work or unread results.
User cancellation must be distinguished from transport loss and other abort causes.

Only current committed assistant public text uses `agentpet.dsh.speech.v1`, with exact
turn/sequence/observation identity and bounded preview text. Reasoning, tool arguments,
credentials and user answers never enter this channel. Recovery does not replay text.

## Independent health query

Request: `{"schema":1,"operation":"status","requestID":"<uuid>"}`.
The reply echoes schema/requestID and returns profileID, hostID, hostStartedAt,
`protocolMajor`, `capabilities`, `packageVersion`, `clientCount`, `eventConnected`
and `eventSocket`. Package version is diagnostic only. `protocolMajor: 1` plus
`lifecycle.v1` establishes lifecycle compatibility. Optional capabilities are
`pending.v1`, `navigation.v1`, `speech.v1`, `bindings.v1`. Unknown capabilities and
additional fields are ignored. Unknown protocol major versions are explicitly
incompatible. Client-dependent capabilities are available only with one live Client.

Health works with zero sessions and has no model request, navigation, task creation,
answer, approval or read-receipt effect. `eventConnected` must report the publisher's
actual connection to `eventSocket`; AgentPet checks its selected event socket as well.
The consumer must report protocol, event transport and capability failures separately.
Multiple current instances for one Profile are ambiguous and must not be guessed.
Old v1 adapters without health queries may still be verified by fresh valid task
observations plus a verified endpoint; absence of a task is not proof of failure.

## Binding query

Request fields: schema 1, operation `binding`, unique UUID requestID, current hostID,
profileID and exact agy conversationID. Response echoes the four identity fields and
returns result `matched`, `notFound`, `ambiguous` or `unavailable`; only `matched` adds
nativeSessionID. The adapter owns its host-specific binding lookup. AgentPet must not
parse DSH or another plugin's private files to establish this relation. Lookup is
read-only, bounded and never activates a session. No account details are returned.

## Navigation and evolution

The existing schema 1 `navigate` request and verified receipt are unchanged. Exact
request/Profile/Host/session/Client generation must match. A selected page is verified
again after foreground activation before acknowledging the displayed notification.
Health or binding queries never acknowledge a task. Unknown operations are rejected;
there are no answer, approve, stop or arbitrary execution commands.

Compatible additions use optional fields/capabilities. Breaking required semantics
requires a new protocol major and an explicit consumer migration. Keep old v1 event
output while adding capabilities so an existing AgentPet can continue consuming
compatible releases. Conformance tests use synthetic records, never real user sessions.
