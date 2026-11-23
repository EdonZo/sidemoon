import Foundation
import Testing
@testable import SidemoonCompanion
@testable import SidemoonCore

// Everything here runs in temporary folders; nothing touches the real home folder or shell files.

private let c = CompanionConstants.ShellIntegration.self

/// A temporary folder standing in for a home folder, removed at the end.
private final class TempHome {
    let path: String
    init() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("sidemoon-shell-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }
    func write(_ name: String, _ text: String, permissions: Int16? = nil) {
        let p = file(name)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: p, atomically: true, encoding: .utf8)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: p) }
    }
    func read(_ name: String) -> String? { try? String(contentsOfFile: file(name), encoding: .utf8) }
    func exists(_ name: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: file(name))) != nil }
    func mkdir(_ name: String) { try? FileManager.default.createDirectory(atPath: file(name), withIntermediateDirectories: true) }
    func backups(of name: String) -> [String] {
        let dir = (file(name) as NSString).deletingLastPathComponent
        let prefix = (name as NSString).lastPathComponent + Constants.Paths.backupSuffix
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) }
    }
    var launcher: String { file(".local/bin/sidemoon-claude") }

    func integration(loginShell: String = "/bin/zsh") -> ShellIntegration {
        ShellIntegration(home: path, loginShell: loginShell, launcher: launcher, fileSystem: SystemShellFileSystem())
    }
}

/// Runs a program and returns what it printed (stdout and stderr) and its exit status.
private func run(_ executable: String, _ arguments: [String], environment: [String: String], cwd: String? = nil) -> (String, Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.environment = environment
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ("could not run \(executable): \(error)", -1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

/// A stand-in program that prints its name and then each argument on a line of its own.
private func fakeProgram(at path: String, name: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? "#!/bin/sh\necho \(name)\nfor a in \"$@\"; do echo \"[$a]\"; done\n".write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: path)
}

// MARK: The block, as text

@Suite struct ShellBlockTests {
    let block = ShellBlock.text(.zshOrBash, launcher: "/Users/me/.local/bin/sidemoon-claude", home: "/Users/me")

    @Test func theBlockForEachShell() {
        #expect(block == """
            # >>> sidemoon >>>
            # Added by Sidemoon: claude starts through sidemoon-claude, so Sidemoon can send to it. Turn it off in Sidemoon's Setup.
            function claude { if [ -x "$HOME/.local/bin/sidemoon-claude" ]; then "$HOME/.local/bin/sidemoon-claude" "$@"; else command claude "$@"; fi; }
            # <<< sidemoon <<<

            """)
        let profile = ShellBlock.text(.bashInSharedProfile, launcher: "/Users/me/.local/bin/sidemoon-claude", home: "/Users/me")
        #expect(profile.contains(#"if [ -n "${BASH_VERSION-}" ]; then eval 'function claude { if [ -x "$HOME/.local/bin/sidemoon-claude" ]"#))
        let fish = ShellBlock.text(.fish, launcher: "/Users/me/.local/bin/sidemoon-claude", home: "/Users/me")
        #expect(fish == """
            # >>> sidemoon >>>
            # Added by Sidemoon: claude starts through sidemoon-claude, so Sidemoon can send to it. Turn it off in Sidemoon's Setup.
            function claude --description 'Claude Code, started through sidemoon-claude so Sidemoon can send to it'
                if test -x "$HOME/.local/bin/sidemoon-claude"
                    "$HOME/.local/bin/sidemoon-claude" $argv
                else
                    command claude $argv
                end
            end
            # <<< sidemoon <<<

            """)
        // A launcher outside the home folder is written out, escaped for each shell's double quotes.
        #expect(ShellBlock.text(.zshOrBash, launcher: "/opt/a$b`c/l", home: "/Users/me").contains(#""/opt/a\$b\`c/l""#))
        #expect(ShellBlock.text(.fish, launcher: "/opt/a$b`c/l", home: "/Users/me").contains(#""/opt/a\$b`c/l""#))
    }

    @Test func addingAndRemovingGivesTheFileBack() throws {
        for original in ["", "export A=1\n", "export A=1", "a\n\nb\n\n", "# notes\n"] {
            let added = try ShellBlock.adding(block, to: original).get()
            #expect(ShellBlock.presence(in: added, expected: block) == .current)
            #expect(added.hasPrefix(original))
            // Idempotent: adding again changes nothing.
            #expect(try ShellBlock.adding(block, to: added).get() == added)
            let removed = try ShellBlock.removing(from: added).get()
            // A missing final newline is the one thing that stays added.
            #expect(removed == (original.isEmpty || original.hasSuffix("\n") ? original : original + "\n"), "\(original)")
        }
        #expect(try ShellBlock.adding(block, to: "x\n").get() == "x\n\n" + block)
        #expect(try ShellBlock.removing(from: "x\n").get() == "x\n")
    }

    @Test func anOlderBlockIsReplacedWhereItIsAndNothingElseMoves() throws {
        let old = "\(c.startMarker)\nalias claude=sidemoon-claude\n\(c.endMarker)\n"
        let text = "before\n" + old + "after\n"
        #expect(ShellBlock.presence(in: text, expected: block) == .outdated)
        let updated = try ShellBlock.adding(block, to: text).get()
        #expect(updated == "before\n" + block + "after\n")
        #expect(try ShellBlock.removing(from: updated).get() == "before\nafter\n")
    }

    @Test func halfABlockIsNeverTouched() {
        for text in ["a\n\(c.startMarker)\nx\n", "\(c.endMarker)\n", "\(c.endMarker)\n\(c.startMarker)\n",
                     "\(c.startMarker)\n\(c.endMarker)\n\(c.startMarker)\n\(c.endMarker)\n"] {
            #expect(ShellBlock.presence(in: text, expected: block) == .malformed)
            #expect(ShellBlock.adding(block, to: text) == .failure(.malformed))
            #expect(ShellBlock.removing(from: text) == .failure(.malformed))
        }
        #expect(ShellBlock.presence(in: "export A=1\n", expected: block) == .absent)
    }
}

// MARK: The files, in a temporary home folder

@Suite struct ShellIntegrationTests {
    @Test func onlyTheShellsInUseAreTouched() {
        let home = TempHome()
        #expect(home.integration().shellsInUse() == [.zsh])
        home.mkdir(".config/fish")
        #expect(home.integration().shellsInUse() == [.zsh, .fish])
        #expect(home.integration().targets().map(\.path) == [home.file(".zshrc"), home.file(".config/fish/functions/claude.fish")])
        // A bash user: .bashrc and the file a login shell reads.
        let bash = TempHome()
        #expect(bash.integration(loginShell: "/bin/bash").targets() == [
            ShellStartupFile(path: bash.file(".bashrc"), shell: .bash, style: .zshOrBash),
            ShellStartupFile(path: bash.file(".bash_profile"), shell: .bash, style: .zshOrBash),
        ])
        // Only .profile: written there (bash-only lines), and no .bash_profile is made to shadow it.
        bash.write(".profile", "export A=1\n")
        #expect(bash.integration(loginShell: "/bin/bash").targets().last
                == ShellStartupFile(path: bash.file(".profile"), shell: .bash, style: .bashInSharedProfile))
        bash.write(".bash_login", "export B=1\n")
        #expect(bash.integration(loginShell: "/bin/bash").targets().last?.path == bash.file(".bash_login"))
        // .profile alone does not mean a zsh user also uses bash; a .bashrc does.
        #expect(bash.integration().shellsInUse() == [.zsh, .bash])
        let zshOnly = TempHome()
        zshOnly.write(".profile", "x\n")
        #expect(zshOnly.integration().shellsInUse() == [.zsh])
    }

    @Test func onWritesEachFileOnceWithOneBackupAndOffGivesItBack() throws {
        let home = TempHome()
        let original = "export PATH=\"$HOME/bin:$PATH\"\nalias ll='ls -l'\n"
        home.write(".zshrc", original, permissions: 0o600)
        home.mkdir(".config/fish")
        let shell = home.integration()
        #expect(shell.status().state == .off)

        let on = shell.enable()
        #expect(on.skipped.isEmpty)
        #expect(Set(on.changed) == [home.file(".zshrc"), home.file(".config/fish/functions/claude.fish")])
        // Only the file that existed is backed up, and the backup is the file as it was.
        #expect(on.backups.count == 1)
        #expect(try String(contentsOfFile: on.backups[0], encoding: .utf8) == original)
        #expect(home.read(".zshrc")?.hasPrefix(original) == true)
        #expect((try FileManager.default.attributesOfItem(atPath: home.file(".zshrc")))[.posixPermissions] as? Int == 0o600)
        #expect(shell.status().state == .on)

        // Again: nothing to do.
        #expect(shell.enable() == ShellChangeReport())

        let off = shell.disable()
        #expect(off.skipped.isEmpty)
        #expect(off.backups.isEmpty, "backed up once, before the first change")
        #expect(home.read(".zshrc") == original)
        // The fish file held only Sidemoon's function, so it goes.
        #expect(!home.exists(".config/fish/functions/claude.fish"))
        #expect(home.backups(of: ".zshrc").count == 1)
        #expect(shell.status().state == .off)
    }

    @Test func aFileSidemoonCreatedIsRemovedAgain() {
        let home = TempHome()
        let shell = home.integration()
        #expect(shell.enable().backups.isEmpty)
        #expect(home.exists(".zshrc"))
        _ = shell.disable()
        #expect(!home.exists(".zshrc"))
    }

    @Test func linksReadOnlyFilesAndOtherPeoplesFunctionsAreLeftAlone() throws {
        let home = TempHome()
        home.write("dotfiles/zshrc", "export A=1\n")
        try FileManager.default.createSymbolicLink(atPath: home.file(".zshrc"), withDestinationPath: home.file("dotfiles/zshrc"))
        home.write(".bashrc", "export B=1\n", permissions: 0o444)
        home.write(".config/fish/functions/claude.fish", "function claude\n    command claude --verbose $argv\nend\n")
        let shell = home.integration()
        let report = shell.enable()
        #expect(report.changed == [home.file(".bash_profile")])
        #expect(Set(report.skipped) == [
            ShellSkip(path: home.file(".zshrc"), reason: .obstacle(.symlink)),
            ShellSkip(path: home.file(".bashrc"), reason: .obstacle(.unwritable)),
            ShellSkip(path: home.file(".config/fish/functions/claude.fish"), reason: .obstacle(.foreignFunction)),
        ])
        #expect(home.read("dotfiles/zshrc") == "export A=1\n")
        #expect(home.read(".bashrc") == "export B=1\n")
        #expect(home.read(".config/fish/functions/claude.fish")?.contains("--verbose") == true)
        #expect(shell.status().state == .partial)
        #expect(shell.status().obstacles.count == 3)
        // Off takes out what it put in, and still does not touch the others.
        let off = shell.disable()
        #expect(off.changed == [home.file(".bash_profile")])
        #expect(!home.exists(".bash_profile"))
        #expect(home.read("dotfiles/zshrc") == "export A=1\n")
    }

    @Test func aBlockIsFoundAndRemovedWhereverSidemoonMayHaveWrittenIt() {
        let home = TempHome()
        let shell = home.integration()
        let block = ShellBlock.text(.bashInSharedProfile, launcher: home.launcher, home: home.path)
        // Bash is not in use any more (no .bashrc, not the login shell), but a block is still in .profile.
        home.write(".profile", "export A=1\n\n" + block)
        #expect(!shell.shellsInUse().contains(.bash))
        #expect(shell.status().state == .partial)
        _ = shell.disable()
        #expect(home.read(".profile") == "export A=1\n")
        // A block from before, in a file Sidemoon still writes, is brought up to date by turning it on.
        home.write(".zshrc", "x\n\n\(c.startMarker)\nold\n\(c.endMarker)\n")
        #expect(shell.status().targets.first?.presence == .outdated)
        _ = shell.enable()
        #expect(home.read(".zshrc") == "x\n\n" + ShellBlock.text(.zshOrBash, launcher: home.launcher, home: home.path))
        #expect(shell.status().state == .on)
    }

    @Test func halfABlockIsReportedNotFixed() {
        let home = TempHome()
        home.write(".zshrc", "x\n\(c.startMarker)\n")
        let report = home.integration().enable()
        #expect(report.skipped == [ShellSkip(path: home.file(".zshrc"), reason: .obstacle(.malformed))])
        #expect(home.read(".zshrc") == "x\n\(c.startMarker)\n")
    }

    // MARK: The blocks in real shells

    /// A home with a fake launcher and a fake `claude` on PATH, both printing what they got.
    private func shellRig() -> (TempHome, [String: String]) {
        let home = TempHome()
        fakeProgram(at: home.launcher, name: "launcher")
        fakeProgram(at: home.file("bin/claude"), name: "claude")
        let env = ["HOME": home.path, "ZDOTDIR": home.path, "PATH": "\(home.file("bin")):/usr/bin:/bin", "TERM": "dumb"]
        return (home, env)
    }

    private func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { $0 == "launcher" || $0 == "claude" || $0.hasPrefix("[") }
    }

    @Test func zshAndBashSendClaudeThroughTheLauncherAndFallBackWithoutIt() {
        let (home, env) = shellRig()
        let shell = home.integration(loginShell: "/bin/bash")
        home.write(".zshrc", "alias claude='claude --flag-from-alias'\n")
        home.write(".bashrc", "")
        _ = shell.enable()
        let call = "claude one 'two words'"
        // An alias defined before the block does not break it, and still goes through the launcher.
        #expect(lines(run("/bin/zsh", ["-i", "-c", call], environment: env).0)
                == ["launcher", "[--flag-from-alias]", "[one]", "[two words]"])
        #expect(lines(run("/bin/bash", ["-i", "-c", call], environment: env).0) == ["launcher", "[one]", "[two words]"])
        #expect(lines(run("/bin/bash", ["-l", "-c", call], environment: env).0) == ["launcher", "[one]", "[two words]"])
        // The launcher (or the app with it) gone: plain claude, unchanged.
        try? FileManager.default.removeItem(atPath: home.launcher)
        #expect(lines(run("/bin/bash", ["-l", "-c", call], environment: env).0) == ["claude", "[one]", "[two words]"])
        #expect(lines(run("/bin/zsh", ["-i", "-c", call], environment: env).0)
                == ["claude", "[--flag-from-alias]", "[one]", "[two words]"])
    }

    @Test func theProfileBlockOnlyRunsUnderBash() {
        let (home, env) = shellRig()
        home.write(".profile", "export A=1\n")
        _ = home.integration(loginShell: "/bin/bash").enable()
        #expect(home.read(".profile")?.contains("BASH_VERSION") == true)
        #expect(lines(run("/bin/bash", ["-l", "-c", "claude x"], environment: env).0) == ["launcher", "[x]"])
        // Other shells read .profile too: there the lines do nothing, and nothing fails.
        for other in ["/bin/dash", "/bin/sh"] where FileManager.default.isExecutableFile(atPath: other) {
            let (output, status) = run(other, ["-c", ". \"$HOME/.profile\"; echo ok"], environment: env)
            #expect(status == 0, "\(other): \(output)")
            #expect(output.hasSuffix("ok\n"), "\(other): \(output)")
        }
    }

    @Test func fishLoadsTheFunctionFileAndFallsBack() throws {
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let fish else { return }
        let (home, env) = shellRig()
        home.mkdir(".config/fish")
        _ = home.integration().enable()
        let call = "claude one 'two words'"
        #expect(lines(run(fish, ["-c", call], environment: env).0) == ["launcher", "[one]", "[two words]"])
        try FileManager.default.removeItem(atPath: home.launcher)
        #expect(lines(run(fish, ["-c", call], environment: env).0) == ["claude", "[one]", "[two words]"])
    }
}

// MARK: The launcher decides what gets the channel

@Suite struct LauncherPassThroughTests {
    /// Runs the real launcher script with a fake `claude` that prints what it got.
    private func launch(_ arguments: [String], helperExists: Bool = true, configExists: Bool = true) -> [String] {
        let home = TempHome()
        let helper = home.file("Sidemoon.app/Contents/Helpers/sidemoon")
        let config = home.file("Library/Application Support/Sidemoon/channel-mcp.json")
        if helperExists { fakeProgram(at: helper, name: "helper") }
        if configExists { home.write("Library/Application Support/Sidemoon/channel-mcp.json", "{}\n") }
        fakeProgram(at: home.file("bin/claude"), name: "claude")
        home.write("launcher", LauncherScript.content(configPath: config, helper: helper, home: home.path))
        let env = ["HOME": home.path, "PATH": "\(home.file("bin")):/usr/bin:/bin"]
        return run("/bin/sh", [home.file("launcher")] + arguments, environment: env).0
            .split(separator: "\n").dropFirst().map { String($0.dropFirst().dropLast()) }
            .map { $0.replacingOccurrences(of: home.path, with: "~") }
    }

    private let channel = ["--mcp-config=~/Library/Application Support/Sidemoon/channel-mcp.json",
                           "--dangerously-load-development-channels=server:sidemoon"]

    @Test func sessionStartsGetTheChannel() {
        #expect(launch([]) == channel)
        #expect(launch(["--resume"]) == channel + ["--resume"])
        #expect(launch(["--resume", "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"]) == channel + ["--resume", "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"])
        // A prompt, even one that starts with a subcommand's name, is a session start.
        #expect(launch(["update the readme"]) == channel + ["update the readme"])
        #expect(launch(["--model", "opus", "-c"]) == channel + ["--model", "opus", "-c"])
        // After --, nothing is read as a flag.
        #expect(launch(["--", "-p"]) == channel + ["--", "-p"])
    }

    @Test func everythingElseRunsPlainClaude() {
        for sub in CompanionConstants.Launcher.passThroughSubcommands {
            #expect(launch([sub, "x"]) == [sub, "x"], "\(sub)")
        }
        for args in [["-p", "hi"], ["--model", "opus", "--print"], ["--bg", "do it"], ["--background"], ["-v"], ["--version"],
                     ["-h"], ["--help"], ["--desktop", "--resume"], ["--cloud"], ["--cloud=fix it"], ["--environment=ccpool_1"]] {
            #expect(launch(args) == args, "\(args)")
        }
        // Sidemoon (its helper) or its config gone: plain claude.
        #expect(launch(["--resume"], helperExists: false) == ["--resume"])
        #expect(launch([], configExists: false) == [])
    }
}

// MARK: Open in Terminal

@Suite struct TerminalReopenTests {
    let id = "0b8e8a52-3f0e-4a8e-9d6f-2c7a1f6b9e01"
    let launcher = "/Users/me/.local/bin/sidemoon-claude"

    @Test func theScriptQuotesTheFolderAndFiltersTheId() {
        let script = TerminalReopen.script(sessionId: id, folder: "/Users/me/My \"Project\" it's", launcher: launcher)
        #expect(script == """
            #!/bin/sh
            cd '/Users/me/My "Project" it'\\''s' 2>/dev/null || { printf '%s %s\\n' 'Sidemoon could not reopen this session: its folder no longer exists:' '/Users/me/My "Project" it'\\''s'; exit 1; }
            exec '/Users/me/.local/bin/sidemoon-claude' --resume '\(id)'

            """)
        // An id with anything else in it is left out: Claude Code then lists the sessions.
        #expect(TerminalReopen.script(sessionId: "abc; rm -rf ~", folder: nil, launcher: launcher)
                == "#!/bin/sh\nexec '/Users/me/.local/bin/sidemoon-claude' --resume\n")
        #expect(!TerminalReopen.script(sessionId: nil, folder: "", launcher: launcher).contains("cd "))
    }

    @Test func nothingOpensWhenItCannotWork() {
        let exists = PathChecks(folderExists: { $0 == "/here" }, isExecutable: { $0 == "/Users/me/.local/bin/sidemoon-claude" })
        #expect(TerminalReopen.plan(sessionId: id, folder: "/gone", launcher: launcher, checks: exists) == .folderGone("/gone"))
        #expect(TerminalReopen.plan(sessionId: id, folder: "/here", launcher: "/nowhere", checks: exists) == .installLauncher)
        #expect(TerminalReopen.plan(sessionId: id, folder: "/here", launcher: launcher, checks: exists)
                == .open(script: TerminalReopen.script(sessionId: id, folder: "/here", launcher: launcher)))
    }

    @Test func theScriptStopsWithOneLineWhenTheFolderIsGone() {
        let home = TempHome()
        let fake = home.file("bin/sidemoon-claude")
        fakeProgram(at: fake, name: "launcher")
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        home.mkdir("a 'quoted' folder")
        let there = TerminalReopen.script(sessionId: id, folder: home.file("a 'quoted' folder"), launcher: fake)
        home.write("there.sh", there)
        let (out, status) = run("/bin/sh", [home.file("there.sh")], environment: env)
        #expect(status == 0)
        #expect(out == "launcher\n[--resume]\n[\(id)]\n")

        let gone = TerminalReopen.script(sessionId: id, folder: home.file("deleted"), launcher: fake)
        home.write("gone.sh", gone)
        let (message, failed) = run("/bin/sh", [home.file("gone.sh")], environment: env)
        #expect(failed == 1)
        #expect(message == Design.Copy.Unreachable.scriptFolderFailed + " " + home.file("deleted") + "\n")
    }
}
