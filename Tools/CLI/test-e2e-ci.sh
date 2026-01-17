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
    
    cd Examples/HummingbirdDemo
    
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
        cd - > /dev/null
        print_error "Failed to start DemoServer ($encoding) - process died immediately"
        return 1
    fi
    
    echo $pid > "${pid_file}"
    cd - > /dev/null
    
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
    cd Tools/CLI
    
    TRANSPORT_ENCODING=${encoding} $test_command
    
    cd - > /dev/null
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

# Main execution
main() {
    echo "=========================================="
    echo "  Local E2E CI/CD Test Runner"
    echo "=========================================="
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
    
    # Build CLI
    print_step "Building CLI..."
    cd Tools/CLI
    npm ci
    npm run build
    cd - > /dev/null
    print_success "CLI built successfully"
    echo ""
    
    # Build DemoServer
    print_step "Building DemoServer..."
    cd Examples/HummingbirdDemo
    swift build
    cd - > /dev/null
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
