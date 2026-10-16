import Foundation

public protocol Embedder: AnyObject {
    func info() throws -> SidecarClient.Info
    func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]]
}

/// An embedder backed by a worker process that is relaunched after it dies.
public final class SidecarEmbedder: Embedder {
    public enum Failure: Error, Equatable { case unavailable(String) }

    private let launch: () throws -> SidecarClient
    private let maxRestarts: Int
    private var client: SidecarClient?
    private var restarts = 0
    private var lastFailure = Date.distantPast
    private let cooldown: TimeInterval
    private let lock = NSLock()

    /// After `maxRestarts` deaths in a row the embedder reports itself unavailable, then tries once more every `cooldown` seconds.
    public init(maxRestarts: Int = 3, cooldown: TimeInterval = 60, launch: @escaping () throws -> SidecarClient) {
        self.maxRestarts = maxRestarts
        self.cooldown = cooldown
        self.launch = launch
    }

    private func current() throws -> SidecarClient {
        if let client { return client }
        if restarts > maxRestarts {
            if Date().timeIntervalSince(lastFailure) < cooldown {
                throw Failure.unavailable("the embedding worker exited \(restarts) times in a row")
            }
            restarts = maxRestarts            // one more attempt; another failure latches again for a full cooldown
        }
        let fresh = try launch()
        client = fresh
        return fresh
    }

    private func perform<T>(_ operation: (SidecarClient) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let worker = try current()
        do {
            let result = try operation(worker)
            restarts = 0
            return result
        } catch let error as SidecarError {
            switch error {
            case .workerExited, .timeout, .malformed:   // a stream that lost sync cannot be trusted again
                client?.close()
                client = nil
                restarts += 1
                lastFailure = Date()
            case .remote:
                break
            }
            throw error
        }
    }

    static func isWorkerLevel(_ error: Error) -> Bool {
        guard let e = error as? SidecarError else { return false }
        switch e {
        case .workerExited, .timeout, .malformed: return true
        case .remote: return false
        }
    }

    public func info() throws -> SidecarClient.Info { try perform { try $0.info() } }

    public func embed(_ modality: EmbedModality, role: EmbedRole, inputs: [String]) throws -> [[Float]] {
        try perform { try $0.embed(modality, role: role, inputs: inputs) }
    }
}

/// One result per input. Tries the whole batch first; if that fails, retries each input alone so a single bad
/// input (or a worker crash it causes) fails only itself. `unsupported_modality` fails everything at once.
public func embedIsolating(_ embedder: Embedder, _ modality: EmbedModality, role: EmbedRole = .document,
                           inputs: [String]) -> [Result<[Float], Error>] {
    guard !inputs.isEmpty else { return [] }
    do {
        let vectors = try embedder.embed(modality, role: role, inputs: inputs)
        guard vectors.count == inputs.count else {
            throw SidecarError.malformed("expected \(inputs.count) vectors, got \(vectors.count)")
        }
        return vectors.map { .success($0) }
    } catch {
        if let e = error as? SidecarError, case .remote(let code, _) = e, code == "unsupported_modality" {
            return inputs.map { _ in .failure(error) }
        }
        if inputs.count == 1 { return [.failure(error)] }
        let results: [Result<[Float], Error>] = inputs.map { input in
            do { return .success(try embedder.embed(modality, role: role, inputs: [input])[0]) }
            catch { return .failure(error) }
        }
        // Every input failing because the worker died means the worker (not the files) is the problem.
        if results.allSatisfy({ if case .failure(let e) = $0 { return SidecarEmbedder.isWorkerLevel(e) } else { return false } }) {
            let unavailable = SidecarEmbedder.Failure.unavailable("the embedding worker keeps failing")
            return inputs.map { _ in .failure(unavailable) }
        }
        return results
    }
}
