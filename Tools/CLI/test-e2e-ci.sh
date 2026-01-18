#!/bin/bash
# Local E2E test script that mimics GitHub Actions workflow
# This allows testing the CI/CD workflow locally before pushing

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVER_PORT=8080
SERVER_HOST="localhost"
TIMEOUT=30

# Function to print colored output
print_step() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

# Function to wait for server to be ready
wait_for_server() {
    local encoding=$1
    print_step "Waiting for DemoServer ($encoding) to start..."
    
    local elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        if curl -s http://${SERVER_HOST}:${SERVER_PORT}/schema > /dev/null 2>&1; then
            print_success "DemoServer ($encoding) is ready!"
            return 0
        fi
        echo "Waiting... ($elapsed/$TIMEOUT seconds)"
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    print_error "DemoServer ($encoding) failed to start within $TIMEOUT seconds"
    return 1
}

# Function to start DemoServer
start_server() {
    local encoding=$1
    local log_file="/tmp/demoserver-${encoding}.log"
    local pid_file="/tmp/demoserver-${encoding}.pid"
    
    print_step "Starting DemoServer ($encoding)..."
    
    # Get project root and demoserver directory
    local project_root="$(pwd)"
    local demoserver_dir="$project_root/Examples/HummingbirdDemo"
    cd "$demoserver_dir"
    
    # Kill any existing server on this port and SwiftPM processes
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
    pkill -f "swift.*DemoServer" 2>/dev/null || true
    sleep 2  # Give SwiftPM time to release build directory
    
    # Start server in background
    TRANSPORT_ENCODING=${encoding} swift run DemoServer > "${log_file}" 2>&1 &
    local pid=$!
    
    # Check if process is still running (quick validation)
    sleep 1
    if ! kill -0 $pid 2>/dev/null; then
        cd "$project_root"
        print_error "Failed to start DemoServer ($encoding) - process died immediately"
        return 1
    fi
    
    echo $pid > "${pid_file}"
    cd "$project_root"
    
    print_success "DemoServer started with PID $pid using encoding: $encoding"
    return 0
}

# Function to stop DemoServer
stop_server() {
    local encoding=$1
    local pid_file="/tmp/demoserver-${encoding}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        print_step "Stopping DemoServer ($encoding, PID: $pid)..."
        
        # Kill the main process
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        
        # Also kill any SwiftPM processes that might be hanging
        pkill -f "swift.*DemoServer" 2>/dev/null || true
        
        # Wait a bit for SwiftPM to release the build directory
        sleep 3
        
        rm -f "$pid_file"
    fi
    
    # Ensure port is released
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
    sleep 1
}

# Function to run tests for a specific encoding
run_encoding_tests() {
    local encoding=$1
    local test_command=""
    
    case "$encoding" in
        json)
            test_command="npm run test:e2e:jsonObject"
            ;;
        jsonOpcode)
            test_command="npm run test:e2e:opcodeJsonArray"
            ;;
        messagepack)
            test_command="npm run test:e2e:messagepack"
            ;;
        *)
            print_error "Unknown encoding: $encoding"
            return 1
            ;;
    esac
    
    print_step "Running E2E tests ($encoding)..."
    # Get project root (assuming we're in it)
    local project_root="$(pwd)"
    local cli_dir="$project_root/Tools/CLI"
    cd "$cli_dir"
    
    TRANSPORT_ENCODING=${encoding} $test_command
    
    cd "$project_root"
    print_success "E2E tests ($encoding) completed successfully"
}

# Function to show server logs
show_logs() {
    local encoding=$1
    local log_file="/tmp/demoserver-${encoding}.log"
    
    if [ -f "$log_file" ]; then
        echo ""
        echo "=== DemoServer ($encoding) logs ==="
        cat "$log_file"
        echo ""
    fi
}

# Function to check if rebuild is needed
needs_rebuild() {
    local dir=$1
    local src_dir="$dir/src"
    local dist_dir="$dir/dist"
    
    # If dist doesn't exist, need to build
    if [ ! -d "$dist_dir" ]; then
        return 0  # true - needs rebuild
    fi
    
    # Check if any source file is newer than dist
    if find "$src_dir" -type f -newer "$dist_dir" 2>/dev/null | grep -q .; then
        return 0  # true - needs rebuild
    fi
    
    return 1  # false - no rebuild needed
}

# Main execution
main() {
    # Get the script directory and navigate to project root
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(cd "$script_dir/../.." && pwd)"
    cd "$project_root"
    
    # Auto-detect paths
    local sdk_dir="$project_root/sdk/ts"
    local cli_dir="$project_root/Tools/CLI"
    local demoserver_dir="$project_root/Examples/HummingbirdDemo"
    
    # Verify paths exist
    if [ ! -d "$sdk_dir" ]; then
        print_error "SDK directory not found: $sdk_dir"
        exit 1
    fi
    
    if [ ! -d "$cli_dir" ]; then
        print_error "CLI directory not found: $cli_dir"
        exit 1
    fi
    
    if [ ! -d "$demoserver_dir" ]; then
        print_error "DemoServer directory not found: $demoserver_dir"
        exit 1
    fi
    
    echo "=========================================="
    echo "  Local E2E CI/CD Test Runner"
    echo "=========================================="
    echo ""
    echo "Project root: $project_root"
    echo "SDK path: $sdk_dir"
    echo "CLI path: $cli_dir"
    echo "DemoServer path: $demoserver_dir"
    echo ""
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    
    if ! command -v swift &> /dev/null; then
        print_error "Swift is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v node &> /dev/null; then
        print_error "Node.js is not installed or not in PATH"
        exit 1
    fi
    
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed or not in PATH"
        exit 1
    fi
    
    print_success "All prerequisites met"
    echo ""
    
    # Build SDK first (CLI depends on it)
    if needs_rebuild "$sdk_dir"; then
        print_step "Building TypeScript SDK (changes detected)..."
        cd "$sdk_dir"
        npm ci
        npm run build
        cd "$project_root"
        print_success "SDK built successfully"
    else
        print_step "TypeScript SDK is up to date, skipping build"
    fi
    echo ""
    
    # Build CLI
    if needs_rebuild "$cli_dir"; then
        print_step "Building CLI (changes detected)..."
        cd "$cli_dir"
        npm ci
        npm run build
        cd "$project_root"
        print_success "CLI built successfully"
    else
        print_step "CLI is up to date, skipping build"
    fi
    echo ""
    
    # Build DemoServer
    print_step "Building DemoServer..."
    cd "$demoserver_dir"
    swift build
    cd "$project_root"
    print_success "DemoServer built successfully"
    echo ""
    
    # Test each encoding mode
    local encodings=("json" "jsonOpcode" "messagepack")
    local failed_encodings=()
    
    for encoding in "${encodings[@]}"; do
        echo "=========================================="
        echo "  Testing encoding: $encoding"
        echo "=========================================="
        echo ""
        
        # Start server
        if ! start_server "$encoding"; then
            print_error "Failed to start server for $encoding"
            show_logs "$encoding"
            failed_encodings+=("$encoding")
            continue
        fi
        
        # Wait for server
        if ! wait_for_server "$encoding"; then
            print_error "Server failed to start for $encoding"
            show_logs "$encoding"
            stop_server "$encoding"
            failed_encodings+=("$encoding")
            continue
        fi
        
        # Run tests
        if ! run_encoding_tests "$encoding"; then
            print_error "Tests failed for $encoding"
            show_logs "$encoding"
            failed_encodings+=("$encoding")
        fi
        
        # Stop server
        stop_server "$encoding"
        
        echo ""
    done
    
    # Summary
    echo "=========================================="
    echo "  Test Summary"
    echo "=========================================="
    
    if [ ${#failed_encodings[@]} -eq 0 ]; then
        print_success "All encoding modes passed!"
        exit 0
    else
        print_error "Failed encodings: ${failed_encodings[*]}"
        exit 1
    fi
}

# Trap to ensure cleanup on exit
cleanup() {
    print_warning "Cleaning up..."
    for encoding in "json" "jsonOpcode" "messagepack"; do
        stop_server "$encoding"
    done
    # Kill any remaining processes on the port
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Run main function
main "$@"
