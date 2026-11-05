// Tests/SwiftStateTreeNIOTests/NIOListenBacklogCheckTests.swift
//
// The listen backlog the kernel actually uses (#124): it caps the requested backlog at
// somaxconn without telling the application, so the server reads the cap at startup and warns
// when it is lower. The cap is read through an injected reader, never the host's real file.

import Foundation
import Testing
@testable import SwiftStateTreeNIO

@Suite("NIOWebSocketServerConfiguration: listen backlog cap")
struct NIOListenBacklogCheckTests {

    @Test("A cap below the requested backlog is the effective backlog and needs a warning")
    func capBelowRequested() {
        var readPaths: [String] = []
        let check = NIOWebSocketServerConfiguration.listenBacklogCheck(requested: 4096) { path in
            readPaths.append(path)
            return "128\n"
        }
        #expect(readPaths == ["/proc/sys/net/core/somaxconn"])
        #expect(check.requested == 4096)
        #expect(check.systemCap == 128)
        #expect(check.effective == 128)
        #expect(check.isCapped)
    }

    @Test("A cap at or above the requested backlog leaves it unchanged")
    func capAtOrAboveRequested() {
        for cap in ["4096", "65535", " 4096 \n"] {
            let check = NIOWebSocketServerConfiguration.listenBacklogCheck(requested: 4096) { _ in cap }
            #expect(check.effective == 4096, "cap \(cap)")
            #expect(!check.isCapped, "cap \(cap)")
            #expect(check.systemCap != nil, "cap \(cap)")
        }
    }

    @Test("Without a readable cap the requested backlog is reported as unchecked")
    func capMissingOrUnreadable() {
        // nil: no such file (macOS, or /proc not mounted); the rest do not parse as a positive count
        for contents in [nil, "", "abc", "0", "-5"] as [String?] {
            let check = NIOWebSocketServerConfiguration.listenBacklogCheck(requested: 512) { _ in contents }
            #expect(check.systemCap == nil, "contents \(String(describing: contents))")
            #expect(check.effective == 512)
            #expect(!check.isCapped)
        }
    }

    @Test("The default reader returns nil for a path that does not exist")
    func defaultReaderMissingFile() {
        #expect(NIOWebSocketServerConfiguration.readSystemFile("/nonexistent/somaxconn") == nil)
    }
}
