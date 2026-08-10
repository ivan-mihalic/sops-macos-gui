import Foundation

/// Deletes the scratch directories a test run creates, when that run's process
/// exits.
///
/// ## Why this is a target and not a helper in each test file
///
/// Fixture helpers in this package hand back a plain `URL`, and there are
/// hundreds of call sites. Making each one responsible means editing every one
/// and trusting the next test added to remember. An audit on 2026-08-10 found
/// what that actually produces: three days of `swift test` in a loop had left
/// tens of thousands of fixture trees in `$TMPDIR`, which macOS does not reap
/// while the login session is alive. Nothing in any working tree grew and
/// `git status` stayed clean the whole time, so there was no signal until the
/// disk was.
///
/// Fixing it helper by helper is whack-a-mole — the four test targets have
/// their own scratch builders and 75+ label prefixes between them, and a
/// partial fix leaves the same failure with a smaller constant. So the
/// mechanism lives in one target every test target can depend on, and each
/// scratch builder registers what it creates. The obligation sits in the
/// function that made the directory, which is the one place that cannot forget.
///
/// ## What it does not cover
///
/// `atexit` does not run if the process is killed or crashes, and this repo's
/// notes record `swift test` occasionally hanging at exit. Those runs still
/// leak, which is why `Scripts/clean-test-temp.sh` exists. This makes them the
/// exception rather than every run.
public final class ScratchDirectoryRegistry: @unchecked Sendable {
    public static let shared = ScratchDirectoryRegistry()

    private let lock = NSLock()
    private var roots: [URL] = []
    private var handlerInstalled = false

    /// Takes ownership of `url` for the lifetime of the process.
    ///
    /// Registering is deliberately separate from creating: the caller has
    /// already made the directory the way its suite needs it, and this only
    /// promises to take it away again.
    public func register(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        roots.append(url)
        guard !handlerInstalled else { return }
        handlerInstalled = true
        // A non-capturing closure, because `atexit` takes a C function pointer
        // and Swift will not convert a capturing one.
        atexit { ScratchDirectoryRegistry.shared.removeAll() }
    }

    /// Creates a uniquely-named directory under `$TMPDIR` and registers it.
    ///
    /// The name is `<label>-<UUID>`, which is also the shape
    /// `Scripts/clean-test-temp.sh` matches — the two have to agree, or the
    /// backstop misses exactly the directories this failed to remove.
    public func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        register(url)
        return url
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots.removeAll()
    }
}

public extension URL {
    /// Registers this URL for deletion when the test process exits, and
    /// returns it — so a scratch path can be built and claimed in one
    /// expression, without the call site needing a local just to register it.
    ///
    /// For paths handed to a subprocess that will create the file itself:
    /// registration is a promise to delete, not a claim that the file exists,
    /// and `removeItem` on a path that never appeared is harmless.
    @discardableResult
    func registeredForCleanup() -> URL {
        ScratchDirectoryRegistry.shared.register(self)
        return self
    }
}
