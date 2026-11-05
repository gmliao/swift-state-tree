# usage: python3 cow_patch.py <tree>   (apply the SPIKE_COW instrumentation; revert with git checkout)
import sys, shutil
t = sys.argv[1]
shutil.copy(__file__.rsplit('/',1)[0] + '/SpikeCow.swift', t + '/Sources/SwiftStateTree/Support/SpikeCow.swift')
p = t + '/Sources/SwiftStateTree/Sync/SyncPolicy.swift'; s = open(p).read()
a = '''    public var wrappedValue: Value {
        get { _wrappedValue }
        set {
            // Mark as dirty whenever value is set (no comparison needed)
            _wrappedValue = newValue
            _isDirty = true
        }
    }
'''
b = '''    public var wrappedValue: Value {
        get { _wrappedValue }
        set {
            // Mark as dirty whenever value is set (no comparison needed)
            _wrappedValue = newValue
            _isDirty = true
        }
        // Spike (SPIKE_COW): emulates the get/set path (copy into a temporary, mutate, store back)
        // and accounts the two copies separately; see SpikeCow.
        _modify {
            if SpikeCow.enabled, let ops = Value.self as? any _SpikeCowOps.Type {
                let t0 = ContinuousClock.now
                let holder = withUnsafeMutablePointer(to: &_wrappedValue) { ops.spikeForceUnique(UnsafeMutableRawPointer($0)) }
                if holder.0 { SpikeCow.noteHolder(bytes: holder.2, duration: ContinuousClock.now - t0) }
                var tmp = _wrappedValue
                let t1 = ContinuousClock.now
                let c94 = withUnsafeMutablePointer(to: &tmp) { ops.spikeForceUnique(UnsafeMutableRawPointer($0)) }
                if c94.0 { SpikeCow.note94(bytes: c94.2, duration: ContinuousClock.now - t1) }
                yield &tmp
                _wrappedValue = tmp
            } else {
                var tmp = _wrappedValue
                yield &tmp
                _wrappedValue = tmp
            }
            _isDirty = true
        }
    }
'''
assert s.count(a) == 1; s = s.replace(a, b); open(p, 'w').write(s)
p = t + '/Sources/SwiftStateTree/Runtime/LandKeeper.swift'; s = open(p).read()
def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (a, s.count(a)); s = s.replace(a, b)
rep('    private var isSyncing = false\n', '    private var isSyncing = false\n    /// Spike (SPIKE_COW): per-keeper CoW accumulator.\n    private let spikeCowCycle = SpikeCow.Cycle()\n')
rep('        isSyncing = true\n', '        isSyncing = true\n        SpikeCow.beginCycle(spikeCowCycle)\n')
rep('        isSyncing = false\n', '        isSyncing = false\n        SpikeCow.endCycle(spikeCowCycle)\n')
rep('''        // Directly execute synchronous body - no copying, no async overhead
        return try body(&state)''', '''        // Directly execute synchronous body - no copying, no async overhead
        let spikeCowPrevious = SpikeCow.enter(spikeCowCycle)
        defer { SpikeCow.exit(spikeCowPrevious) }
        return try body(&state)''')
n = s.count('        handler(&state, ctx)\n')
assert n >= 1
s = s.replace('        handler(&state, ctx)\n', '''        do {
            let spikeCowPrevious = SpikeCow.enter(spikeCowCycle)
            defer { SpikeCow.exit(spikeCowPrevious) }
            handler(&state, ctx)
        }
''')
open(p, 'w').write(s)
print('patched', t, 'tick sites', n)
