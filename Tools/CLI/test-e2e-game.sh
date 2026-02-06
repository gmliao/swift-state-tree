#!/bin/bash
# E2E test script specifically for GameServer (hero-defense game)
# This script starts GameServer, runs game tests, and cleans up

set -e  # Exit on error

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/e2e-test-common.sh"

# GameServer startup can be slower (plugin/tooling + fresh container builds),
# so allow a longer readiness window than the common default.
TIMEOUT=${TIMEOUT:-120}

# Server-specific configuration
SERVER_NAME="GameServer"
SERVER_DIR_NAME="GameDemo"
SERVER_CMD="GameServer"

# Function to start GameServer
start_server() {
    local encoding=$1
    local project_root="$(pwd)"
    local server_dir="$project_root/Examples/${SERVER_DIR_NAME}"
    # Normalize encoding: GameServer accepts json_opcode, jsonOpcode, json-opcode
    # Enable reevaluation for reevaluation E2E tests
    export ENABLE_REEVALUATION=true
    start_server_impl "$encoding" "$SERVER_NAME" "$server_dir" "$SERVER_CMD"
}

# Function to run tests for a specific encoding
run_encoding_tests() {
    local encoding=$1
    local state_update_encoding=""
    
    case "$encoding" in
        json)
            state_update_encoding="jsonObject"
            ;;
        jsonOpcode|json_opcode)
            state_update_encoding="opcodeJsonArray"
            ;;
        messagepack)
            state_update_encoding="messagepack"
            ;;
        *)
            print_error "Unknown encoding: $encoding"
            return 1
            ;;
    esac
    
    print_step "Running ${SERVER_NAME} E2E tests ($encoding)..."
    local project_root="$(pwd)"
    local cli_dir="$project_root/Tools/CLI"
    cd "$cli_dir"
    
    # Ensure npm dependencies are installed
    if [ ! -d "node_modules" ]; then
        npm ci
    fi
    
    # Normalize encoding for server (GameServer accepts json_opcode)
    local server_encoding=$(normalize_encoding_for_server "$encoding" "gameserver")
    
    TRANSPORT_ENCODING=${server_encoding} npx tsx src/cli.ts script \
        -u ws://localhost:${SERVER_PORT}/game/hero-defense \
        -l hero-defense \
        -s scenarios/game/ \
        --state-update-encoding ${state_update_encoding}

    # Re-evaluation record + offline verify (Hero Defense): only required for messagepack
    if [ "$encoding" = "messagepack" ]; then
        print_step "Running ${SERVER_NAME} re-evaluation record+verify ($encoding)..."
        HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
            --ws-url ws://localhost:${SERVER_PORT}/game/hero-defense \
            --admin-url http://${SERVER_HOST}:${SERVER_PORT} \
            --state-update-encoding ${state_update_encoding}
    fi
    
    local test_result=$?
    cd "$project_root"
    
    if [ $test_result -eq 0 ]; then
        print_success "${SERVER_NAME} E2E tests ($encoding) completed successfully"
        return 0
    else
        print_error "${SERVER_NAME} E2E tests ($encoding) failed"
        return 1
    fi
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
    echo "  ${SERVER_NAME} E2E Test Runner"
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
    
    # Build GameServer (use -c release when E2E_BUILD_MODE=release)
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
    # Note: Use jsonOpcode in test script, but GameServer accepts json_opcode/jsonOpcode/json-opcode
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
