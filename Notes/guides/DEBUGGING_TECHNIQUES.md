# Debugging Techniques Guide

This document collects practical debugging techniques and Swift build system knowledge used in SwiftStateTree development.

## Table of Contents

1. [Code Search & Investigation](#code-search--investigation)
2. [Data Flow Verification](#data-flow-verification)
3. [Incremental Testing](#incremental-testing)
4. [Output Validation](#output-validation)
5. [Swift Build System](#swift-build-system)
6. [Sanitizers & Memory/Thread Debugging](#sanitizers--memorythread-debugging)
7. [Crash Log Analysis](#crash-log-analysis)
8. [Common Debug Patterns](#common-debug-patterns)

---

## Code Search & Investigation

### 1. Semantic Code Search
Use `codebase_search` to find related code by meaning, not just keywords:

```python
# Example: Finding where CPU monitoring is handled
codebase_search(
    query="How is CPU monitoring collected and processed?",
    target_directories=["Examples/GameDemo/scripts"]
)
```

**When to use:**
- Understanding how a feature works
- Finding related code that might affect the issue
- Discovering hidden dependencies

### 2. Pattern-Based Search
Use `grep` for exact pattern matching:

```bash
# Find all uses of a specific function
grep -r "Task\.sleep\(for:" Sources/

# Find with context (before/after lines)
grep -A 5 -B 5 "pattern" file.swift
```

**When to use:**
- Finding all occurrences of a specific API
- Checking for unsafe patterns (e.g., `String(format:)` with `%s`)
- Verifying code changes across files

### 3. File Structure Exploration
Use `list_dir` and `glob_file_search` to understand project structure:

```python
# List directory contents
list_dir("Examples/GameDemo/scripts")

# Find files by pattern
glob_file_search("**/*monitoring*.py")
```

**When to use:**
- Understanding project organization
- Finding related files
- Locating test files or examples

---

## Data Flow Verification

### 1. Trace Data from Source to Output
When debugging data processing issues, trace the entire pipeline:

**Example: Monitoring data flow**
1. **Source**: Check raw log files (`vmstat.log`, `pidstat.csv`)
2. **Parser**: Test parser with sample data
3. **JSON**: Verify JSON structure and content
4. **HTML**: Check HTML generation and chart data

```python
# Step 1: Check raw data
run_terminal_cmd("head -20 /path/to/vmstat.log")

# Step 2: Test parser
python3 -c "
from parse_monitoring import parse_vmstat_log
samples = parse_vmstat_log(Path('vmstat.log'))
print(f'Samples: {len(samples)}')
print(f'First: {samples[0] if samples else None}')
"

# Step 3: Verify JSON
python3 -c "import json; data = json.load(open('monitoring.json')); print(data.keys())"

# Step 4: Check HTML output
grep -i "cpuChart\|System CPU" report.html
```

### 2. Validate Intermediate Steps
Don't assume data is correct at each step - verify it:

```python
# Bad: Assume parser works
samples = parse_vmstat_log(path)

# Good: Verify parser output
samples = parse_vmstat_log(path)
assert len(samples) > 0, "No samples parsed"
assert "cpu_us_pct" in samples[0], "Missing CPU data"
```

### 3. Compare Expected vs Actual
Always compare what you expect vs what you get:

```python
# Expected: 7 samples with CPU data
# Actual: Check the actual output
expected_samples = 7
actual_samples = len(parse_vmstat_log(path))
if actual_samples != expected_samples:
    print(f"Expected {expected_samples}, got {actual_samples}")
    # Investigate why
```

---

## Incremental Testing

### 1. Start with Minimal Test Case
Don't test the full system immediately - start small:

```bash
# Bad: Run full load test immediately
./run-server-loadtest.sh --rooms 500 --duration-seconds 30

# Good: Start with minimal test
./run-server-loadtest.sh --rooms 2 --duration-seconds 3
```

**Benefits:**
- Faster iteration
- Easier to identify the issue
- Less resource consumption

### 2. Test Components in Isolation
Test individual components before testing the whole system:

```python
# Test parser separately
python3 parse_monitoring.py --vmstat test.log --output test.json

# Test HTML generation separately
python3 parse_monitoring.py --monitoring-json test.json --html test.html
```

### 3. Build Up Complexity Gradually
Add complexity only after each step works:

1. ✅ Parse raw log → JSON
2. ✅ Generate HTML from JSON
3. ✅ Integrate with test results
4. ✅ Add charts and visualizations

---

## Output Validation

### 1. Check File Contents Directly
Don't rely on tool output - check files directly:

```bash
# Check if file exists and has content
ls -lh report.html
head -50 report.html | grep -i "cpu"

# Check JSON structure
python3 -c "import json; print(json.dumps(json.load(open('data.json')), indent=2))"
```

### 2. Verify HTML/JSON Structure
Use grep and read_file to verify structure:

```python
# Check if key elements exist
grep("cpuChart", "report.html")  # Should find chart canvas
grep("VMStat Samples", "report.html")  # Should find summary

# Read specific sections
read_file("report.html", offset=140, limit=50)  # Check monitoring section
```

### 3. Test with Known Good Data
Create test data with known values to verify processing:

```python
# Create test JSON with known structure
test_data = {
    "vmstat": [
        {"cpu_us_pct": 15.0, "cpu_sy_pct": 11.0, "cpu_id_pct": 74.0}
    ]
}
json.dump(test_data, open("test.json", "w"))

# Verify it works
generate_html_report(test_data, Path("test.html"))
```

---

## Swift Build System

### Build Configuration Options

Swift Package Manager uses `-c` (or `--configuration`) to specify build configuration:

```bash
# Debug build (default)
swift build
swift build -c debug

# Release build (optimized)
swift build -c release

# Run with specific configuration
swift run -c release ServerLoadTest
swift run -c debug DemoServer
```

### Common Build Commands

**Compilation:**
```bash
# Build all targets
swift build

# Build with release configuration
swift build -c release

# Build specific product
swift build --product ServerLoadTest -c release
```

**Running:**
```bash
# Run with default (debug) configuration
swift run ServerLoadTest

# Run with release configuration
swift run -c release ServerLoadTest

# Run with arguments
swift run -c release ServerLoadTest --rooms 50 --duration-seconds 10
```

**Testing:**
```bash
# Run all tests (debug mode)
swift test

# Run tests in release mode (for performance testing)
swift test -c release

# Run specific test
swift test --filter StateTreeTests.testGetSyncFields

# List all tests
swift test list
```

### Build Configuration Differences

**Debug (`-c debug` or default):**
- No optimizations
- Debug symbols included
- Assertions enabled
- Faster compilation
- Larger binary size
- Slower runtime performance
- **Use for**: Development, debugging, testing

**Release (`-c release`):**
- Full optimizations (`-O`)
- Debug symbols stripped (smaller binary)
- Assertions may be optimized away
- Slower compilation
- Smaller binary size
- Faster runtime performance
- **Use for**: Production, benchmarks, performance testing

### Important Notes

1. **Release builds can expose bugs** that don't appear in debug:
   - Optimizations can change behavior
   - Assertions may be removed
   - Memory layout can differ
   - Example: `Task.sleep(for:)` crashes only in macOS release builds

2. **Always test in release mode** for:
   - Performance benchmarks
   - Production deployments
   - Final validation before release

3. **Use debug mode for**:
   - Development and debugging
   - Unit tests (unless testing performance)
   - Initial feature development

### Build System Environment Variables

```bash
# Set build configuration via environment
SWIFT_BUILD_CONFIGURATION=release swift build

# Disable parallel compilation (for debugging build issues)
swift build -j 1

# Verbose output
swift build -v

# Show build plan without executing
swift build --dry-run
```

### Sanitizers & Memory/Thread Debugging

Swift supports runtime sanitizers to detect memory issues, thread safety problems, and undefined behavior:

**Address Sanitizer (ASan) - Memory Issues:**
```bash
# Build with Address Sanitizer
swift build -c release -Xswiftc -sanitize=address

# Run with Address Sanitizer
swift run -c release -Xswiftc -sanitize=address ServerLoadTest

# Example: Check for memory leaks, use-after-free, buffer overflows
swift run -c release -Xswiftc -sanitize=address EncodingBenchmark --rooms 2
```

**Thread Sanitizer (TSan) - Data Races:**
```bash
# Build with Thread Sanitizer
swift build -c release -Xswiftc -sanitize=thread

# Run with Thread Sanitizer
swift run -c release -Xswiftc -sanitize=thread ServerLoadTest

# Example: Detect data races in concurrent code
swift run -c release -Xswiftc -sanitize=thread EncodingBenchmark --rooms 2
```

**Undefined Behavior Sanitizer (UBSan):**
```bash
# Build with Undefined Behavior Sanitizer
swift build -c release -Xswiftc -sanitize=undefined

# Detects: integer overflow, null pointer dereference, etc.
```

**Combined Sanitizers:**
```bash
# Use multiple sanitizers (note: some combinations may not work together)
swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined
```

**When to use sanitizers:**
- **Address Sanitizer**: When debugging memory corruption, use-after-free, buffer overflows
- **Thread Sanitizer**: When debugging data races, thread safety issues
- **Undefined Behavior**: When debugging integer overflow, null pointer issues
- **Note**: Sanitizers add significant overhead (2-10x slower), use for debugging only

### Crash Log Analysis

**macOS Crash Reports (.ips files):**

When a process crashes on macOS, crash reports are saved to:
- `~/Library/Logs/DiagnosticReports/` (user crashes)
- `/Library/Logs/DiagnosticReports/` (system crashes)

**View crash logs:**
```bash
# List recent crash reports
ls -lt ~/Library/Logs/DiagnosticReports/*.ips | head -5

# View crash report
open ~/Library/Logs/DiagnosticReports/ServerLoadTest_*.ips

# Or read directly
cat ~/Library/Logs/DiagnosticReports/ServerLoadTest_*.ips | head -100

# Search for specific patterns
grep -i "swift_task_dealloc\|SIGABRT\|EXC_BAD_ACCESS" ~/Library/Logs/DiagnosticReports/*.ips
```

**Key information in crash logs:**
- **Exception Type**: `EXC_BAD_ACCESS`, `SIGABRT`, `EXC_CRASH`
- **Crashed Thread**: Which thread crashed
- **Backtrace**: Function call stack leading to crash
- **Binary Images**: Loaded libraries and their addresses

**Example crash log analysis:**
```
Exception Type:        EXC_CRASH (SIGABRT)
Exception Codes:       0x0000000000000000, 0x0000000000000000

Application Specific Information:
abort() called

Thread 0 Crashed:
0   libsystem_kernel.dylib        0x... __pthread_kill
1   libsystem_pthread.dylib       0x... pthread_kill
2   libsystem_c.dylib             0x... abort
3   libswiftCore.dylib            0x... swift_task_dealloc
4   YourApp                        0x... Task.sleep(for:)  <-- Root cause
```

**Linux Core Dumps:**

```bash
# Enable core dumps
ulimit -c unlimited

# Run program (if it crashes, core dump is created)
./your_program

# Analyze core dump with gdb
gdb ./your_program core
(gdb) bt  # Backtrace
(gdb) info registers
(gdb) print variable_name
```

### Memory Debugging Tools

**macOS:**
```bash
# MallocStackLogging (tracks memory allocations)
export MallocStackLogging=1
swift run -c release ServerLoadTest

# Leaks detection
leaks --atExit -- ./your_program

# Heap analysis
heap ./your_program
```

**Linux:**
```bash
# Valgrind (memory leak detection)
valgrind --leak-check=full --show-leak-kinds=all ./your_program

# Massif (heap profiler)
valgrind --tool=massif ./your_program
ms_print massif.out.*
```

### Thread Debugging

**Check thread state:**
```bash
# macOS: List threads of a process
ps -M <PID>

# Linux: List threads
ps -T -p <PID>
top -H -p <PID>

# Use lldb/gdb to inspect threads
lldb ./your_program
(lldb) thread list
(lldb) thread select <thread_id>
(lldb) bt
```

**Thread Sanitizer output interpretation:**
```
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 8 at 0x... by thread T1:
    #0 MyClass.setValue() file.swift:123
  Previous read of size 8 at 0x... by thread T2:
    #0 MyClass.getValue() file.swift:456
```

### Troubleshooting Build Issues

**Issue: Build fails in release but works in debug**
- Check for optimization-related bugs
- Look for undefined behavior
- Verify all assertions are not required for correctness
- Test with `-O` flag explicitly
- Use sanitizers to detect issues: `-Xswiftc -sanitize=address`

**Issue: Different behavior between debug and release**
- Check for uninitialized variables
- Verify thread-safety (release optimizations can expose race conditions)
- Check for platform-specific bugs (e.g., macOS Swift Concurrency issues)
- Use Thread Sanitizer: `-Xswiftc -sanitize=thread`
- Check crash logs for clues

**Issue: Crashes in release mode**
- Check crash logs (`.ips` files on macOS)
- Look for backtrace patterns (e.g., `swift_task_dealloc`)
- Use Address Sanitizer: `-Xswiftc -sanitize=address`
- Research known Swift runtime bugs
- Test with sanitizers to get more detailed error messages

**Issue: Slow build times**
- Use `-j` to control parallelism: `swift build -j 4`
- Check for unnecessary dependencies
- Consider incremental builds (don't clean between builds)

---

## Common Debug Patterns

### Pattern 1: "It works in isolation but not in integration"

**Symptoms:**
- Component works when tested alone
- Fails when integrated with other components

**Debug Steps:**
1. Check data format compatibility between components
2. Verify file paths and permissions
3. Check for timing/race conditions
4. Look for missing dependencies or initialization

**Example:**
```python
# Parser works standalone
samples = parse_vmstat_log("test.log")  # ✅ Works

# But fails in script
# Check: Is the file path correct? Is it created in time?
```

### Pattern 2: "Data exists but not displayed"

**Symptoms:**
- Data is parsed correctly
- JSON contains expected values
- But HTML report shows empty/zero values

**Debug Steps:**
1. Verify data is passed correctly to HTML generator
2. Check HTML generation logic (conditions, loops)
3. Verify JavaScript chart data is embedded correctly
4. Check browser console for JavaScript errors

**Example:**
```python
# Data exists in JSON
data = json.load(open("monitoring.json"))
print(len(data["vmstat"]))  # ✅ 7 samples

# But HTML shows 0
# Check: Is data passed to generate_html_report()?
# Check: Does HTML generation check for empty lists?
```

### Pattern 3: "Works on one platform but not another"

**Symptoms:**
- Code works on Linux
- Fails on macOS (or vice versa)

**Debug Steps:**
1. Check platform-specific tools/APIs
2. Verify file format differences
3. Check for platform-specific bugs (e.g., Swift runtime bugs)
4. Test with platform detection and fallbacks

**Example:**
```python
# Linux: vmstat works
# macOS: vmstat doesn't exist (different format)
# Solution: Detect OS and use appropriate tool
if OS_TYPE == "Linux":
    use_vmstat()
elif OS_TYPE == "Darwin":
    # macOS alternatives have issues
    disable_monitoring()
```

### Pattern 4: "Intermittent failures"

**Symptoms:**
- Sometimes works, sometimes fails
- No clear pattern

**Debug Steps:**
1. Check for race conditions
2. Look for timing dependencies
3. Verify resource cleanup
4. Check for memory leaks or resource exhaustion

**Example:**
```python
# Task.sleep crashes intermittently on macOS release builds
# Root cause: Swift Concurrency runtime bug
# Solution: Use safe wrapper (safeTaskSleep)
```

### Pattern 5: "Works in debug but fails in release"

**Symptoms:**
- Code works with `swift build` (debug)
- Crashes or behaves differently with `swift build -c release`

**Debug Steps:**
1. Check for undefined behavior (uninitialized variables, out-of-bounds access)
2. Look for optimization-related bugs
3. Verify thread-safety (optimizations can expose race conditions)
4. Check for platform-specific runtime bugs (e.g., Swift Concurrency on macOS)
5. Test with sanitizers: `swift build -c release -Xswiftc -sanitize=thread`

**Example:**
```swift
// This crashes in release but not debug on macOS
try await Task.sleep(for: delay)  // ❌ Crashes in release

// Solution: Use safe wrapper
try await safeTaskSleep(for: delay)  // ✅ Works in release
```

---

## Debugging Workflow

### Step-by-Step Process

1. **Reproduce the Issue**
   - Create minimal test case
   - Document exact steps to reproduce
   - Note any error messages or unexpected behavior
   - Test in both debug and release modes

2. **Gather Information**
   - Check logs and error messages
   - Verify file contents and data structures
   - Test individual components
   - Check platform differences (macOS vs Linux)

3. **Form Hypothesis**
   - Based on symptoms, form a hypothesis
   - Think about what could cause this behavior
   - Consider platform-specific issues
   - Research known bugs (Swift runtime, platform tools)

4. **Test Hypothesis**
   - Create targeted test to verify hypothesis
   - Use incremental testing approach
   - Verify each step
   - Test in both debug and release modes

5. **Fix and Verify**
   - Implement fix
   - Test with minimal case
   - Test with full system
   - Test in both debug and release modes
   - Verify fix doesn't break other things

6. **Document**
   - Document the issue and solution
   - Update relevant documentation
   - Add comments to code if needed
   - Note platform-specific workarounds

---

## Tools & Commands Reference

### Code Search
- `codebase_search`: Semantic search for understanding code
- `grep`: Pattern-based search for exact matches
- `glob_file_search`: Find files by pattern

### File Operations
- `read_file`: Read file contents (with offset/limit for large files)
- `list_dir`: List directory contents
- `grep`: Search file contents

### Testing
- `run_terminal_cmd`: Execute shell commands
- `read_lints`: Check for linter errors
- `swift build`: Compile and check for errors
- `swift build -c release`: Build with optimizations
- `swift test`: Run tests
- `swift test -c release`: Run tests in release mode

### Data Validation
- `python3 -c "..."`: Quick Python one-liners for data inspection
- `json.load()`: Parse and validate JSON
- `grep` with patterns: Check file contents

---

## Real-World Examples

### Example 1: Debugging Missing CPU Chart

**Issue**: CPU chart not appearing in HTML report

**Debug Process:**
1. Check if data exists: `grep "VMStat Samples" report.html` → Shows 0
2. Check raw log: `head vmstat.log` → Data exists
3. Test parser: `python3 parse_monitoring.py --vmstat vmstat.log` → Parses correctly
4. Check JSON: `python3 -c "import json; ..."` → JSON has 7 samples
5. Check HTML generation: Read `generate_html_report()` → Found condition `if vmstat_samples:`
6. Root cause: Data not passed correctly to HTML generator
7. Fix: Verify data flow from JSON → HTML generator

### Example 2: Debugging macOS Monitoring Issues

**Issue**: macOS monitoring data not collected

**Debug Process:**
1. Check OS detection: `uname -s` → Darwin
2. Check tool availability: `which vmstat` → Not found (Linux only)
3. Test alternatives: `iostat -w 1` → Works but format different
4. Test parser: Parser doesn't recognize iostat format
5. Root cause: Parser only handles Linux vmstat format
6. Fix: Add macOS iostat format detection and parsing (or disable on macOS)

### Example 3: Debugging Swift Runtime Crash

**Issue**: Release build crashes on macOS

**Debug Process:**
1. Reproduce: `swift run -c release ServerLoadTest` → Crashes with SIGABRT
2. Check crash logs: `*.ips` files show `swift_task_dealloc` in backtrace
3. Search code: `grep "Task.sleep" Sources/` → Found usage
4. Research: Web search confirms Swift Concurrency bug
5. Root cause: `Task.sleep(for: Duration)` bug on macOS release builds
6. Fix: Create `safeTaskSleep()` wrapper using `Task.sleep(nanoseconds:)`
7. Verify: Test in both debug and release modes

---

## Tips for AI Agents

1. **Don't assume** - Always verify data at each step
2. **Start small** - Test with minimal cases first
3. **Trace the flow** - Follow data from source to output
4. **Compare expected vs actual** - Know what you expect
5. **Test in isolation** - Test components separately
6. **Test in both modes** - Always test debug AND release builds
7. **Document findings** - Keep notes of what you discover
8. **Use the right tool** - Semantic search vs pattern search
9. **Read error messages** - They often point to the issue
10. **Check platform differences** - macOS vs Linux differences
11. **Verify fixes** - Test that fix works and doesn't break other things
12. **Research known bugs** - Swift runtime, platform tools, etc.

---

## Related Resources

- `.agent/skills/Superpowers/systematic-debugging/`: Systematic debugging skill
- `AGENTS.md`: AI agent guidelines and troubleshooting reference
- `Examples/GameDemo/MESSAGEPACK_INVESTIGATION.md`: Example investigation report
