#!/bin/bash
# Local E2E test script that mimics GitHub Actions workflow
# This allows testing the CI/CD workflow locally before pushing

set -e  # Exit on error

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/e2e-test-common.sh"

# Use release server when E2E_BUILD_MODE=release (e.g. E2E_BUILD_MODE=release ./test-e2e-ci.sh)

# Server-specific configuration
SERVER_NAME="DemoServer"
SERVER_DIR_NAME="HummingbirdDemo"
SERVER_CMD="DemoServer"

# Function to start DemoServer
start_server() {
    local encoding=$1
    local project_root="$(pwd)"
    local server_dir="$project_root/Examples/${SERVER_DIR_NAME}"
    start_server_impl "$encoding" "$SERVER_NAME" "$server_dir" "$SERVER_CMD"
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
    local project_root="$(pwd)"
    local cli_dir="$project_root/Tools/CLI"
    cd "$cli_dir"
    
    TRANSPORT_ENCODING=${encoding} $test_command
    
    cd "$project_root"
    print_success "E2E tests ($encoding) completed successfully"
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
    local server_dir="$project_root/Examples/${SERVER_DIR_NAME}"
    
    # Verify paths exist
    if [ ! -d "$sdk_dir" ]; then
        print_error "SDK directory not found: $sdk_dir"
        exit 1
    fi
    
    if [ ! -d "$cli_dir" ]; then
        print_error "CLI directory not found: $cli_dir"
        exit 1
    fi
    
    if [ ! -d "$server_dir" ]; then
        print_error "${SERVER_NAME} directory not found: $server_dir"
        exit 1
    fi
    
    echo "=========================================="
    echo "  Local E2E CI/CD Test Runner"
    echo "=========================================="
    echo ""
    echo "Project root: $project_root"
    echo "SDK path: $sdk_dir"
    echo "CLI path: $cli_dir"
    echo "${SERVER_NAME} path: $server_dir"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Build SDK and CLI
    build_sdk "$project_root"
    build_cli "$project_root"
    
    # Build DemoServer (use -c release when E2E_BUILD_MODE=release)
    print_step "Building ${SERVER_NAME} (${E2E_BUILD_MODE:-debug})..."
    cd "$server_dir"
    if [ "$E2E_BUILD_MODE" = "release" ]; then
        swift build -c release
    else
        swift build
    fi
    cd "$project_root"
    print_success "${SERVER_NAME} built successfully"
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
            show_logs "$SERVER_NAME" "$encoding"
            failed_encodings+=("$encoding")
            continue
        fi
        
        # Wait for server
        if ! wait_for_server "$SERVER_NAME" "$encoding"; then
            print_error "Server failed to start for $encoding"
            show_logs "$SERVER_NAME" "$encoding"
            stop_server "$SERVER_NAME" "$encoding"
            failed_encodings+=("$encoding")
            continue
        fi
        
        # Run tests
        if ! run_encoding_tests "$encoding"; then
            print_error "Tests failed for $encoding"
            show_logs "$SERVER_NAME" "$encoding"
            failed_encodings+=("$encoding")
        fi
        
        # Stop server
        stop_server "$SERVER_NAME" "$encoding"
        
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
    cleanup_servers "$SERVER_NAME" "json" "jsonOpcode" "messagepack"
}

trap cleanup EXIT INT TERM

# Run main function
main "$@"
