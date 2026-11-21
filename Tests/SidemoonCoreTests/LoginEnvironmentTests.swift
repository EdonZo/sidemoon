import Foundation
import Testing
@testable import SidemoonCore

private let marker = Constants.LoginShell.marker

/// Builds shell output: noise, marker, NUL-terminated entries, marker, noise.
private func output(_ entries: [String], before: String = "", after: String = "") -> Data {
    var d = Data(before.utf8)
    d.append(Data(marker.utf8))
    for e in entries { d.append(Data(e.utf8)); d.append(0) }
    d.append(Data(marker.utf8))
    d.append(Data(after.utf8))
    return d
}

@Suite struct LoginEnvironmentTests {
    @Test func ignoresNoiseOutsideMarkers() throws {
        let data = output(["PATH=/opt/homebrew/bin:/usr/bin", "HOME=/Users/me"],
                          before: "Last login: today\nwelcome NOISE=1\n", after: "\nbye OTHER=2\n")
        let env = try #require(LoginEnvironment.parse(data))
        #expect(env == ["PATH": "/opt/homebrew/bin:/usr/bin", "HOME": "/Users/me"])
    }

    @Test func keepsMultiLineValuesAndEqualsSigns() throws {
        let data = output(["PATH=/usr/bin", "MULTI=line one\nline two\n", "EQ=a=b=c"])
        let env = try #require(LoginEnvironment.parse(data))
        #expect(env["MULTI"] == "line one\nline two\n")
        #expect(env["EQ"] == "a=b=c")
    }

    @Test func missingMarkersIsNil() {
        #expect(LoginEnvironment.parse(Data("PATH=/usr/bin\0HOME=/x\0".utf8)) == nil)
        var oneMarker = Data(marker.utf8)
        oneMarker.append(Data("PATH=/usr/bin\0".utf8))
        #expect(LoginEnvironment.parse(oneMarker) == nil)
    }

    @Test func missingPathIsNil() {
        #expect(LoginEnvironment.parse(output(["HOME=/Users/me"])) == nil)
        #expect(LoginEnvironment.parse(output(["PATH="])) == nil)
    }

    @Test func stripsNestedSessionMarkers() {
        var env = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        for name in Constants.LoginShell.strippedVariables { env[name] = "1" }
        #expect(LoginEnvironment.sanitized(env) == ["PATH": "/usr/bin", "HOME": "/Users/me"])
    }

    @Test func realLoginShellHasPath() throws {
        let env = try #require(LoginEnvironment.load())
        #expect(!(env[Constants.LoginShell.pathVariable] ?? "").isEmpty)
        let shared = LoginEnvironment.shared
        #expect(!(shared[Constants.LoginShell.pathVariable] ?? "").isEmpty)
        for name in Constants.LoginShell.strippedVariables { #expect(shared[name] == nil) }
    }
}
