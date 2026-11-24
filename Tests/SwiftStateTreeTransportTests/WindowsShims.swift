// Windows has no POSIX `usleep`, which some tests call; this file supplies it there only.
#if os(Windows)
import WinSDK

/// Sleeps for about `microseconds`, rounded up to whole milliseconds. `Sleep` follows the system
/// timer (a tick is about 16 ms), so it can return a little early or late; a test must not
/// depend on a precise pause.
func usleep(_ microseconds: UInt32) {
    // Not `(microseconds + 999) / 1000`: that overflows for values near `UInt32.max`.
    let milliseconds = microseconds / 1000 + (microseconds % 1000 == 0 ? 0 : 1)
    Sleep(DWORD(milliseconds))
}
#endif
