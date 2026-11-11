import AgentPetCore
import Foundation

/// One exact Team association identity. An asynchronous host result is only
/// applied while the current session still presents the identity it was
/// requested for, so a stale `.matched` can never write an old conversation
/// back (and stamp a fresh check on it), and a stale failure can never clear a
/// newer identity's verification.
struct AionUiAssociationToken: Equatable {
    let sessionCreatedAt: Date
    let conversationID: String?
    let teamID: String?
    let teamRole: AionUiConversation.TeamRole?

    init(_ session: AgentSession) {
        sessionCreatedAt = session.createdAt
        conversationID = session.aionUiConversation?.id
        teamID = session.aionUiConversation?.teamID
        teamRole = session.aionUiConversation?.teamRole
    }

    func matches(_ session: AgentSession) -> Bool {
        self == AionUiAssociationToken(session)
    }
}

/// Per-association failure clock key. A changed identity starts a new clock
/// instead of inheriting the old one.
struct AionUiVerificationKey: Hashable {
    let sessionID: String
    let conversationID: String?
    let teamID: String?
    let teamRole: AionUiConversation.TeamRole?

    init(sessionID: String, conversationID: String?, teamID: String?,
         teamRole: AionUiConversation.TeamRole?) {
        self.sessionID = sessionID
        self.conversationID = conversationID
        self.teamID = teamID
        self.teamRole = teamRole
    }

    init(_ session: AgentSession) {
        self.init(sessionID: session.id,
                  conversationID: session.aionUiConversation?.id,
                  teamID: session.aionUiConversation?.teamID,
                  teamRole: session.aionUiConversation?.teamRole)
    }
}

/// Bounded grace for a cached Team verification that stopped being confirmed.
///
/// The cached verification itself is dropped **immediately** on the first
/// unverifiable check (a stored verification is only ever current evidence of
/// the check that produced it). This window only governs how long the verified
/// **role** survives repeated failures before the row degrades to the explicit
/// neutral "current state unconfirmed" presentation. A successful re-check
/// clears the window, so the same identity self-heals.
struct TeamVerificationWatchdog {
    /// The host check is throttled to ~2 s, so this is a bounded number of
    /// missed checks, never an unbounded "still valid" window.
    static let window: TimeInterval = 60

    private var unverifiedSince: [AionUiVerificationKey: Date] = [:]

    /// Records one unverifiable check. Returns true exactly once the same
    /// association has stayed unverifiable for the whole grace window.
    mutating func noteUnverifiable(_ key: AionUiVerificationKey, now: Date) -> Bool {
        guard let since = unverifiedSince[key] else {
            unverifiedSince[key] = now
            return false
        }
        return now.timeIntervalSince(since) >= Self.window
    }

    /// A successful re-check heals the association: a session carries exactly
    /// one association at a time, so every clock for it is cleared.
    mutating func noteVerified(_ key: AionUiVerificationKey) {
        unverifiedSince = unverifiedSince.filter { $0.key.sessionID != key.sessionID }
    }

    func isPending(_ sessionID: String) -> Bool {
        unverifiedSince.keys.contains { $0.sessionID == sessionID }
    }

    /// Drops bookkeeping for sessions that are no longer tracked.
    mutating func retain(_ ids: Set<String>) {
        unverifiedSince = unverifiedSince.filter { ids.contains($0.key.sessionID) }
    }
}

/// What one host association result means for a tracked session's cached Team
/// verification.
enum AionUiVerificationAction: Equatable {
    case ignore
    case apply(AionUiMetadata.Record)
    /// The cached verification is no longer current; `clearRole` also drops the
    /// verified identity after the bounded grace window.
    case invalidate(clearRole: Bool)
}

/// Pure decision behind every host check, so the real application chain (not
/// just the grace timer) is testable without a running app.
enum AionUiVerificationPolicy {
    static func action(for lookup: AionUiMetadata.Lookup, session: AgentSession, now: Date,
                       watchdog: inout TeamVerificationWatchdog) -> AionUiVerificationAction {
        let key = AionUiVerificationKey(session)
        switch lookup {
        case .matched(let record):
            watchdog.noteVerified(key)
            return .apply(record)
        case .notFound, .unavailable, .ambiguous:
            // Only an association whose live check already succeeded has a
            // cached verification to drop or a role to invalidate.
            guard session.aionUiTeamScope != nil, session.validAionUiTeam != nil else { return .ignore }
            return .invalidate(clearRole: watchdog.noteUnverifiable(key, now: now))
        }
    }
}

/// Applies one confirmed record and reports whether the bubble must refresh:
/// losing or regaining the *currency* of an unchanged identity is a real
/// display change even though nothing is written to the snapshot.
enum AionUiVerificationApplier {
    @discardableResult
    static func apply(_ record: AionUiMetadata.Record, for session: AgentSession, in store: SessionStore,
                      verifiedAt: Date) -> Bool {
        let wasCurrent = BubblePresentation.isCurrentlyVerified(session, now: verifiedAt)
        let persisted = store.updateAionUiMetadata(id: session.id, createdAt: session.createdAt,
                                                   record: record, verifiedAt: verifiedAt)
        let isCurrent = store.session(id: session.id)
            .map { BubblePresentation.isCurrentlyVerified($0, now: verifiedAt) } ?? false
        return persisted || wasCurrent != isCurrent
    }
}
