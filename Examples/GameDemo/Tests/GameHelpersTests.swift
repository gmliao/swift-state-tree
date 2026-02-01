import Testing
@testable import GameContent

struct GameHelpersTests {

    @Test("getEnvBool returns default when missing")
    func testGetEnvBoolDefault() {
        #expect(getEnvBool(key: "MISSING_FLAG", defaultValue: true, environment: [:]) == true)
        #expect(getEnvBool(key: "MISSING_FLAG", defaultValue: false, environment: [:]) == false)
    }

    @Test("getEnvBool parses truthy/falsy values")
    func testGetEnvBoolParsing() {
        let truthy = ["1", "true", "yes", "y", "on", "TRUE"]
        for value in truthy {
            #expect(getEnvBool(key: "FLAG", defaultValue: false, environment: ["FLAG": value]) == true)
        }

        let falsy = ["0", "false", "no", "n", "off", "FALSE"]
        for value in falsy {
            #expect(getEnvBool(key: "FLAG", defaultValue: true, environment: ["FLAG": value]) == false)
        }

        #expect(getEnvBool(key: "FLAG", defaultValue: true, environment: ["FLAG": "maybe"]) == true)
        #expect(getEnvBool(key: "FLAG", defaultValue: false, environment: ["FLAG": "maybe"]) == false)
    }
}
