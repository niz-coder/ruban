import Foundation

/// Starts a process that lives on after Ruban: the guardian, or the script that installs an update.
enum Spawn {
    /// Runs `args` (the program first) with no input and no output. `disclaim` makes it answer for
    /// its own permissions (Accessibility), `newSession` detaches it from Ruban's session.
    /// Returns its pid, or nil with the reason in the log.
    @discardableResult
    static func detached(_ args: [String], disclaim: Bool = false, newSession: Bool = false) -> pid_t? {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if newSession { posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) }
        // Private, looked up at runtime: macOS then checks the permissions against the program
        // itself rather than against Ruban, which may be gone by the time it needs them.
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        if disclaim, let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
            _ = unsafeBitCast(p, to: Disclaim.self)(&attr, 1)
        }
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, args[0], &files, &attr, &argv, environ)
        guard status == 0 else {
            Log.write("could not start \((args[0] as NSString).lastPathComponent): \(String(cString: strerror(status)))")
            return nil
        }
        return pid
    }
}
