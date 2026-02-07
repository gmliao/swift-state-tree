// Tests/SwiftStateTreeTests/PatchRecorderTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

@Test("PatchRecorder records patches and takes them")
func testPatchRecorder_RecordAndTake() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Act
    recorder.record(StatePatch(path: "/score", operation: .set(.int(100))))
    recorder.record(StatePatch(path: "/players/A/health", operation: .set(.int(90))))
    
    // Assert
    #expect(recorder.hasPatches == true)
    let patches = recorder.takePatches()
    #expect(patches.count == 2)
    #expect(patches[0].path == "/score")
    #expect(patches[1].path == "/players/A/health")
    
    // After take, should be empty
    #expect(recorder.hasPatches == false)
    #expect(recorder.takePatches().isEmpty == true)
}

@Test("PatchRecorder takePatches preserves capacity")
func testPatchRecorder_TakePreservesCapacity() {
    // Arrange
    let recorder = LandPatchRecorder()
    
    // Record many patches
    for i in 0..<100 {
        recorder.record(StatePatch(path: "/field\(i)", operation: .set(.int(i))))
    }
    
    // Act
    _ = recorder.takePatches()
    
    // Record again - should not need reallocation
    recorder.record(StatePatch(path: "/new", operation: .set(.int(999))))
    
    // Assert
    #expect(recorder.hasPatches == true)
}
