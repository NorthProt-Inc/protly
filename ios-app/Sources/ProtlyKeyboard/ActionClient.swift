import Foundation
import ProtlyCore

/// One Translate/Polish/Read call, streamed. The request and the reading of the reply are ProtlyCore's
/// (ActionAPI.request, ActionAPI.updates); URLSession is here. Never on the main actor: building the request, the
/// download and the parsing all run in the stream's producer task, and only the consumer hops back.
enum ActionClient {
    /// One session for the process: ephemeral, no cache, no cookies, no redirects (ActionAPI).
    private static let session = URLSession(
        configuration: ActionAPI.sessionConfiguration(), delegate: ActionSessionDelegate(), delegateQueue: nil)
    /// Deep's own session, made at the first Deep: URLSession fixes the total timeout per session (240 s, not 90 s).
    private static let deepSession = URLSession(
        configuration: ActionAPI.sessionConfiguration(profile: .deep), delegate: ActionSessionDelegate(), delegateQueue: nil)

    /// Partial translations, then exactly one done or failed. Ending the consumer (its task cancelled) cancels the
    /// download; a cancel ends the stream with nothing more. `profile` .deep is the Deep re-run: its own session and
    /// twice the reply bytes.
    static func run(_ mode: ActionMode, text: String, profile: ActionProfile = .normal) -> AsyncStream<ActionUpdate> {
        #if PROTLY_CI_STUB
        // The simulator CI only (StubActionClient.swift): a marker draft gets a recorded stream, before the key.
        if let stub = StubActionClient.run(mode, text: text) { return stub }
        #endif
        let session = profile == .deep ? deepSession : session
        return ActionAPI.updates(limit: profile.maxResponseBytes) { () async throws -> (status: Int, bytes: URLSession.AsyncBytes, stop: @Sendable () -> Void) in
            let (bytes, response) = try await session.bytes(for: request(mode, text: text, profile: profile))
            let task = bytes.task
            // The timeouts stay URLSession's (ActionAPI.sessionConfiguration): both cancel this read.
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, bytes, { task.cancel() })
        }
    }

    /// The request, or the ActionError to show without sending anything.
    private static func request(_ mode: ActionMode, text: String, profile: ActionProfile) throws -> URLRequest {
        guard let base = try? ActionAPI.bundledPrompt() else { throw ActionError(.setup) }
        // The about-me note joins Translate (out) and Polish (fix) only. AboutMe.system leaves Read clipboard (in) as is.
        let note = UserDefaults.standard.string(forKey: AboutMe.defaultsKey) ?? ""
        let system = AboutMe.system(base: base, note: note, mode: mode)
        return try ActionAPI.request(mode: mode, text: text, system: system, apiKey: Secrets.apiKey, profile: profile).get()
    }
}
