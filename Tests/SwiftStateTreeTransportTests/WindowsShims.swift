// Windows has no POSIX `usleep`, which some tests call; this file supplies it there only.
#if os(Windows)
import WinSDK

/// Sleeps for at least `microseconds`, rounded up to whole milliseconds (the granularity of `Sleep`).
func usleep(_ microseconds: UInt32) {
    Sleep(DWORD((microseconds + 999) / 1000))
}
#endif
