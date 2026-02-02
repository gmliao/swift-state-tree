#!/bin/bash
# Common functions for E2E test scripts
# This file provides shared utilities for test-e2e-ci.sh and test-e2e-game.sh
#
# Usage:
#   source "$(dirname "$0")/e2e-test-common.sh"
#   SERVER_NAME="DemoServer"  # or "GameServer"
#   SERVER_DIR="Examples/HummingbirdDemo"  # or "Examples/GameDemo"
#   SERVER_CMD="DemoServer"  # or "GameServer"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration (can be overridden by calling script)
SERVER_PORT=${SERVER_PORT:-8080}
SERVER_HOST=${SERVER_HOST:-localhost}
TIMEOUT=${TIMEOUT:-30}
# E2E_BUILD_MODE=release to run server in release (default: debug)
E2E_BUILD_MODE=${E2E_BUILD_MODE:-}

# E2E artifacts directory (logs, pid files).
# Default: <repoRoot>/tmp/e2e (repoRoot is the current working directory of the calling script).
# Override with E2E_TMP_DIR (absolute path recommended).
get_e2e_tmp_dir() {
    local base_dir="${E2E_TMP_DIR:-$(pwd)/tmp/e2e}"
    echo "$base_dir"
}

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
    local server_name=$1
    local encoding=$2
    print_step "Waiting for ${server_name} ($encoding) to start..."
    
    local elapsed=0
    while [ $elapsed -lt $TIMEOUT ]; do
        if curl -s http://${SERVER_HOST}:${SERVER_PORT}/schema > /dev/null 2>&1; then
            print_success "${server_name} ($encoding) is ready!"
            return 0
        fi
        echo "Waiting... ($elapsed/$TIMEOUT seconds)"
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    print_error "${server_name} ($encoding) failed to start within $TIMEOUT seconds"
    return 1
}

# Function to convert string to lowercase (compatible with bash 3.2+)
to_lowercase() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Function to start server (must be implemented by calling script)
# This is a placeholder - actual implementation depends on server type
start_server_impl() {
    local encoding=$1
    local server_name=$2
    local server_dir=$3
    local server_cmd=$4
    local server_name_lower=$(to_lowercase "$server_name")
    
    print_step "Starting ${server_name} ($encoding)..."
    
    # Get project root
    local project_root="$(pwd)"
    local tmp_dir="${E2E_TMP_DIR:-${project_root}/tmp/e2e}"
    mkdir -p "$tmp_dir"
    local log_file="${tmp_dir}/${server_name_lower}-${encoding}.log"
    local pid_file="${tmp_dir}/${server_name_lower}-${encoding}.pid"
    cd "$server_dir"
    
    # Kill any existing server on this port and SwiftPM processes
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
    pkill -f "swift.*${server_cmd}" 2>/dev/null || true
    sleep 2  # Give SwiftPM time to release build directory
    
    # Normalize encoding name for server (both accept jsonOpcode/json_opcode)
    local server_encoding="$encoding"
    if [ "$encoding" = "jsonOpcode" ]; then
        server_encoding="json_opcode"  # GameServer uses underscore
    fi
    
    # Start server in background (use -c release when E2E_BUILD_MODE=release)
    local swift_run_cmd="swift run"
    if [ "$E2E_BUILD_MODE" = "release" ]; then
        swift_run_cmd="swift run -c release"
    fi
    TRANSPORT_ENCODING=${server_encoding} $swift_run_cmd ${server_cmd} > "${log_file}" 2>&1 &
    local pid=$!
    
    # Check if process is still running (quick validation)
    sleep 1
    if ! kill -0 $pid 2>/dev/null; then
        cd "$project_root"
        print_error "Failed to start ${server_name} ($encoding) - process died immediately"
        return 1
    fi
    
    echo $pid > "${pid_file}"
    cd "$project_root"
    
    print_success "${server_name} started with PID $pid using encoding: $encoding"
    return 0
}

# Function to stop server
stop_server() {
    local server_name=$1
    local encoding=$2
    local server_name_lower=$(to_lowercase "$server_name")
    local tmp_dir="$(get_e2e_tmp_dir)"
    local pid_file="${tmp_dir}/${server_name_lower}-${encoding}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        print_step "Stopping ${server_name} ($encoding, PID: $pid)..."
        
        # Kill the main process
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        
        # Also kill any SwiftPM processes that might be hanging
        # Use lowercase for pattern matching
        pkill -f "swift.*${server_name_lower}" 2>/dev/null || true
        
        # Wait a bit for SwiftPM to release the build directory
        sleep 3
        
        rm -f "$pid_file"
    fi
    
    # Ensure port is released
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
    sleep 1
}

# Function to show server logs
show_logs() {
    local server_name=$1
    local encoding=$2
    local server_name_lower=$(to_lowercase "$server_name")
    local tmp_dir="$(get_e2e_tmp_dir)"
    local log_file="${tmp_dir}/${server_name_lower}-${encoding}.log"
    
    if [ -f "$log_file" ]; then
        echo ""
        echo "=== ${server_name} ($encoding) logs ==="
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

# Function to check prerequisites
check_prerequisites() {
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
}

# Function to build SDK
build_sdk() {
    local project_root=$1
    local sdk_dir="$project_root/sdk/ts"
    
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
}

# Function to build CLI
build_cli() {
    local project_root=$1
    local cli_dir="$project_root/Tools/CLI"
    
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
}

# Function to cleanup servers
cleanup_servers() {
    local server_name=$1
    local encodings=("${@:2}")  # All remaining arguments are encodings
    print_warning "Cleaning up..."
    for encoding in "${encodings[@]}"; do
        stop_server "$server_name" "$encoding"
    done
    # Kill any remaining processes on the port
    lsof -ti:${SERVER_PORT} | xargs kill -9 2>/dev/null || true
}

# Function to normalize encoding names
# Converts between different naming conventions used by different servers
normalize_encoding_for_server() {
    local encoding=$1
    local server_type=$2  # "demoserver" or "gameserver"
    
    case "$encoding" in
        jsonOpcode|json_opcode|json-opcode)
            if [ "$server_type" = "gameserver" ]; then
                echo "json_opcode"
            else
                echo "jsonOpcode"
            fi
            ;;
        *)
            echo "$encoding"
            ;;
    esac
}
