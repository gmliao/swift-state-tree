#!/bin/bash
# E2E test script specifically for GameServer (hero-defense game)
# This script starts GameServer, runs game tests, and cleans up

set -e  # Exit on error

# assertConverged gates by default in this script: a convergence mismatch fails the run.
# Set E2E_CONVERGENCE_GATING=false for a report-only run.
export E2E_CONVERGENCE_GATING="${E2E_CONVERGENCE_GATING:-true}"

# GameServer startup can be slower (plugin/tooling + fresh container builds),
# so allow a longer readiness window than the common default.
# Must be set BEFORE sourcing e2e-test-common.sh to override its default.
export TIMEOUT=${TIMEOUT:-120}

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e-test-common.sh
source "${SCRIPT_DIR}/e2e-test-common.sh"

# Debug state routes for the assertConverged step (#79), guarded by the admin key.
export ENABLE_DEBUG_STATE_ROUTES=true
export E2E_ADMIN_KEY=${E2E_ADMIN_KEY:-${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key}}

# Server-specific configuration
SERVER_NAME="GameServer"
SERVER_DIR_NAME="GameDemo"
SERVER_CMD="GameServer"

# Function to start GameServer
start_server() {
    local encoding=$1
    local project_root
    project_root="$(pwd)"
    local server_dir="$project_root/Examples/${SERVER_DIR_NAME}"
    # Normalize encoding: GameServer accepts json_opcode, jsonOpcode, json-opcode
    # Enable reevaluation for reevaluation E2E tests
    export ENABLE_REEVALUATION=true
    start_server_impl "$encoding" "$SERVER_NAME" "$server_dir" "$SERVER_CMD"
}

# Map a server encoding to the CLI's state update decoding mode
state_update_encoding_for() {
    case "$1" in
        json) echo "jsonObject" ;;
        jsonOpcode|json_opcode) echo "opcodeJsonArray" ;;
        messagepack) echo "messagepack" ;;
        *) return 1 ;;
    esac
}

# Run the hero-defense CLI scenarios (run from Tools/CLI)
run_cli_scenarios() {
    local encoding=$1
    local state_update_encoding
    state_update_encoding=$(state_update_encoding_for "$encoding") || return 1
    local server_encoding
    server_encoding=$(normalize_encoding_for_server "$encoding" "gameserver")
    local scenario_path="${E2E_SCENARIO:-scenarios/game/}"
    TRANSPORT_ENCODING=${server_encoding} npx tsx src/cli.ts script \
        -u "ws://localhost:${SERVER_PORT}/game/hero-defense" \
        -l hero-defense \
        -s "$scenario_path" \
        --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
        --state-update-encoding "${state_update_encoding}"
}

# The visibility test land (#65): per-player projection with 3 clients, convergence checked at
# the view edges (enter, leave, swap, exit and re-entry within one sync). It runs in every
# encoding, since per-player filtering and the dynamic-key table are encoding-sensitive. The
# land is on the same GameServer, so it adds no server start.
run_visibility_scenarios() {
    local encoding=$1
    local state_update_encoding
    state_update_encoding=$(state_update_encoding_for "$encoding") || return 1
    npx tsx src/cli.ts script \
        -u "ws://localhost:${SERVER_PORT}/game/visibility-test" \
        -l visibility-test \
        -s scenarios/visibility-test/ \
        --clients 3 \
        --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
        --state-update-encoding "${state_update_encoding}"
}

# The resolver test land (#65): a slow resolver keeps the tick going, and a failed or timed-out
# resolver leaves the state unchanged. Messagepack only: the resolver path does not depend on
# the encoding.
run_resolver_scenarios() {
    local encoding=$1
    local state_update_encoding
    state_update_encoding=$(state_update_encoding_for "$encoding") || return 1
    npx tsx src/cli.ts script \
        -u "ws://localhost:${SERVER_PORT}/game/resolver-test" \
        -l resolver-test \
        -s scenarios/resolver-test/ \
        --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
        --state-update-encoding "${state_update_encoding}"
}

# Graceful shutdown (#351): SIGTERM shuts GameServer down through its shutdown path. It exits
# 0 after its "Shutdown finished" summary, and a hero-defense land still alive at the signal
# (its 5 s destroy-when-empty delay not over yet) is destroyed through the normal path, so its
# record is saved. Run from the repository root.
run_graceful_shutdown_check() {
    local encoding="messagepack"
    local project_root
    project_root="$(pwd)"
    local records_dir
    records_dir=$(mktemp -d)
    local log_file
    log_file="$(get_e2e_tmp_dir)/gameserver-${encoding}.log"
    local pid_file
    pid_file="$(get_e2e_tmp_dir)/gameserver-${encoding}.pid"
    local result=1
    export REEVALUATION_RECORDS_DIR="$records_dir"
    if start_server "$encoding" && wait_for_server "$SERVER_NAME" "$encoding"; then
        if (cd "$project_root/Tools/CLI" && E2E_SCENARIO=scenarios/game/test-direct-mode-regression.json run_cli_scenarios "$encoding"); then
            local before after pid status
            before=$(find "$records_dir" -name 'hero-defense-*.sstr' | wc -l | tr -d ' ')
            pid=$(cat "$pid_file")
            kill -TERM "$pid"
            # Bounded: a shutdown that hangs (the bug class checked here) is killed after 20 s,
            # well past the 10 s worst case at the default timeout, instead of holding the job.
            ( sleep 20; kill -9 "$pid" 2>/dev/null ) &
            local timer=$!
            status=0
            wait "$pid" || status=$?
            kill "$timer" 2>/dev/null || true
            wait "$timer" 2>/dev/null || true
            after=$(find "$records_dir" -name 'hero-defense-*.sstr' | wc -l | tr -d ' ')
            # The server's log lines carry ANSI colors around their values.
            local summary
            summary=$(sed $'s/\x1b\\[[0-9;]*m//g' "$log_file" | grep "Shutdown finished" || true)
            if [ "$status" -eq 137 ]; then
                print_error "GameServer didn't exit within 20 s of SIGTERM: killed"
            elif [ "$status" -ne 0 ]; then
                print_error "GameServer exited with status $status after SIGTERM"
            elif [ -z "$summary" ]; then
                print_error "No shutdown summary in the GameServer log"
            elif ! grep -qE "landsDestroyed=[1-9]" <<< "$summary"; then
                print_error "The shutdown destroyed no land: $summary"
            elif [ "$after" -le "$before" ]; then
                print_error "The shutdown saved no record (records before: $before, after: $after)"
            else
                print_success "SIGTERM: exit 0, $((after - before)) record(s) saved by the shutdown"
                echo "$summary"
                result=0
            fi
        fi
    fi
    [ "$result" -eq 0 ] || show_logs "$SERVER_NAME" "$encoding"
    stop_server "$SERVER_NAME" "$encoding"
    unset REEVALUATION_RECORDS_DIR
    rm -rf "$records_dir"
    return "$result"
}

# Function to run tests for a specific encoding
run_encoding_tests() {
    local encoding=$1
    local state_update_encoding
    if ! state_update_encoding=$(state_update_encoding_for "$encoding"); then
        print_error "Unknown encoding: $encoding"
        return 1
    fi
    
    print_step "Running ${SERVER_NAME} E2E tests ($encoding)..."
    local project_root
    project_root="$(pwd)"
    local cli_dir="$project_root/Tools/CLI"
    cd "$cli_dir"
    
    # Ensure npm dependencies are installed
    if [ ! -d "node_modules" ]; then
        npm ci
    fi
    
    # Each step is checked explicitly: `set -e` does not apply inside a function called from `if !`.
    local failed_step=""
    run_cli_scenarios "$encoding" || failed_step="CLI scenarios"
    if [ -z "$failed_step" ]; then
        print_step "Running visibility-test scenarios ($encoding, 3 clients)..."
        run_visibility_scenarios "$encoding" || failed_step="visibility-test scenarios"
    fi
    if [ -z "$failed_step" ] && [ "$encoding" = "messagepack" ]; then
        print_step "Running resolver-test scenarios ($encoding)..."
        run_resolver_scenarios "$encoding" || failed_step="resolver-test scenarios"
    fi

    # Negative test (#79), tick land and broadcast path in json: a client that drops the one
    # /score diff must fail assertConverged with that path. Gating is forced on for this run.
    if [ -z "$failed_step" ] && [ "$encoding" = "json" ]; then
        print_step "Running convergence fault injection (drop one /score patch, $encoding)..."
        local fault_log
        fault_log=$(mktemp)
        if npx tsx src/cli.ts script \
            -u "ws://localhost:${SERVER_PORT}/game/hero-defense" \
            -l hero-defense \
            -s scenarios/fault/hero-defense-drop-score.json \
            --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
            --state-update-encoding "${state_update_encoding}" \
            --fault-drop-patch /score \
            --convergence-gating > "$fault_log" 2>&1; then
            cat "$fault_log"
            print_error "Fault injection: assertConverged passed although the /score patch was dropped"
            failed_step="fault injection (/score)"
        elif ! grep -q "CONVERGENCE MISMATCH (gating) fault-drop-score" "$fault_log" || ! grep -qE "^  /score: client=" "$fault_log"; then
            cat "$fault_log"
            print_error "Fault injection: the script failed, but not with a /score convergence mismatch"
            failed_step="fault injection (/score)"
        else
            grep -E "CONVERGENCE MISMATCH|^  /score: " "$fault_log"
            print_success "Fault injection detected: dropped /score patch reported with its path"
        fi
        rm -f "$fault_log"
    fi

    # Optional load variant (#79): E2E_CONVERGENCE_LOAD=true runs the burst scenario with
    # E2E_LOAD_CLIENTS clients in each of E2E_LOAD_ROOMS parallel rooms. Mismatches fail it
    # like the other steps (gating, see the top of this script); route and timeout errors too.
    if [ -z "$failed_step" ] && [ "${E2E_CONVERGENCE_LOAD:-false}" = "true" ]; then
        print_step "Running ${SERVER_NAME} convergence load variant ($encoding, ${E2E_LOAD_CLIENTS:-4} clients x ${E2E_LOAD_ROOMS:-4} rooms)..."
        local server_encoding
        server_encoding=$(normalize_encoding_for_server "$encoding" "gameserver")
        TRANSPORT_ENCODING=${server_encoding} npx tsx src/cli.ts script \
            -u "ws://localhost:${SERVER_PORT}/game/hero-defense" \
            -l hero-defense \
            -s scenarios/load/hero-defense-burst.json \
            --clients "${E2E_LOAD_CLIENTS:-4}" \
            --rooms "${E2E_LOAD_ROOMS:-4}" \
            --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
            --state-update-encoding "${state_update_encoding}" || failed_step="convergence load variant"
    fi

    # Re-evaluation record + offline verify (Hero Defense): only required for messagepack
    if [ -z "$failed_step" ] && [ "$encoding" = "messagepack" ]; then
        print_step "Running ${SERVER_NAME} re-evaluation record+verify ($encoding)..."
        HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
            --ws-url "ws://localhost:${SERVER_PORT}/game/hero-defense" \
            --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
            --state-update-encoding "${state_update_encoding}" || failed_step="re-evaluation record+verify"

        if [ -z "$failed_step" ]; then
            print_step "Running visibility-test re-evaluation record+verify ($encoding)..."
            HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
                --ws-url "ws://localhost:${SERVER_PORT}/game/visibility-test" \
                --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
                --land-type visibility-test \
                --scenario scenarios/visibility-test/test-visibility-edges.json \
                --clients 3 \
                --state-update-encoding "${state_update_encoding}" || failed_step="visibility-test re-evaluation record+verify"
        fi

        if [ -z "$failed_step" ]; then
            # Successes and failures mixed: only applied actions are recorded, with their
            # resolver outputs, so the replay matches without calling the service.
            print_step "Running resolver-test re-evaluation record+verify ($encoding)..."
            HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
                --ws-url "ws://localhost:${SERVER_PORT}/game/resolver-test" \
                --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
                --land-type resolver-test \
                --scenario scenarios/resolver-test/test-resolver-outcomes.json \
                --clients 1 \
                --state-update-encoding "${state_update_encoding}" || failed_step="resolver-test re-evaluation record+verify"
        fi

        if [ -z "$failed_step" ]; then
            # Transport events as inputs (#219): a disconnect, a leave (the server removes the
            # player) and a rejoin as the same player are recorded, and the replay matches.
            print_step "Running ${SERVER_NAME} reconnect re-evaluation record+verify ($encoding)..."
            HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
                --ws-url "ws://localhost:${SERVER_PORT}/game/hero-defense" \
                --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
                --scenario scenarios/game/test-reconnect-rebuild.json \
                --clients 1 \
                --state-update-encoding "${state_update_encoding}" || failed_step="reconnect re-evaluation record+verify"
        fi

        if [ -z "$failed_step" ]; then
            # Two connections with one playerID (#69, #92): the newer join supersedes the older
            # session, which the server closes; the rest converge and the replay matches.
            print_step "Running ${SERVER_NAME} supersede re-evaluation record+verify ($encoding)..."
            HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-e2e-game.ts \
                --ws-url "ws://localhost:${SERVER_PORT}/game/hero-defense" \
                --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
                --scenario scenarios/game/test-join-supersede.json \
                --clients 1 \
                --state-update-encoding "${state_update_encoding}" || failed_step="supersede re-evaluation record+verify"
        fi

        if [ -z "$failed_step" ]; then
            print_step "Running ${SERVER_NAME} replay record verification ($encoding)..."
            HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/verify-replay-record.ts \
                --admin-url="http://${SERVER_HOST}:${SERVER_PORT}" \
                --wait-ms=12000 \
                --min-events=1 || failed_step="replay record verification"
        fi
    fi

    # Server-side replay stream should pass in all transport encodings.
    if [ -z "$failed_step" ]; then
        print_step "Running ${SERVER_NAME} server replay stream E2E ($encoding)..."
        HERO_DEFENSE_ADMIN_KEY=${HERO_DEFENSE_ADMIN_KEY:-hero-defense-admin-key} npx tsx src/reevaluation-replay-e2e-game.ts \
            --ws-url "ws://localhost:${SERVER_PORT}/game/hero-defense" \
            --admin-url "http://${SERVER_HOST}:${SERVER_PORT}" \
            --state-update-encoding "${state_update_encoding}" || failed_step="server replay stream"
    fi

    cd "$project_root"
    
    if [ -z "$failed_step" ]; then
        print_success "${SERVER_NAME} E2E tests ($encoding) completed successfully"
        return 0
    else
        print_error "${SERVER_NAME} E2E tests ($encoding) failed: $failed_step"
        return 1
    fi
}

# Main execution
main() {
    # Get the script directory and navigate to project root
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root
    project_root="$(cd "$script_dir/../.." && pwd)"
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
    # E2E_ENCODINGS narrows the list (space-separated), e.g. to the opcode encodings for a run
    # with ROW_ADDRESSING=true, which needs one.
    local encodings
    read -r -a encodings <<< "${E2E_ENCODINGS:-json jsonOpcode messagepack}"
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

    echo "=========================================="
    echo "  Graceful shutdown on SIGTERM (#351)"
    echo "=========================================="
    if ! run_graceful_shutdown_check; then
        failed_encodings+=("graceful shutdown")
    fi
    echo ""

    # The opt-out leg: messagepack with the typed sync tables and typed leaf values off, the
    # snapshot-diff fallback. Same CLI scenarios (broadcast field, broadcast event,
    # assertConverged); no replay. The server's config log line must show the tables off, so
    # the leg can't pass on the default path (row addressing would turn them back on).
    local variant="messagepack (USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false)"
    echo "=========================================="
    echo "  Testing encoding: $variant"
    echo "=========================================="
    echo ""
    export USE_SYNC_TABLES=false TYPED_LEAF_VALUES=false
    if start_server "messagepack" && wait_for_server "$SERVER_NAME" "messagepack"; then
        print_step "Running ${SERVER_NAME} E2E scenarios ($variant)..."
        local variant_log
        variant_log="$(get_e2e_tmp_dir)/gameserver-messagepack.log"
        if ! (cd "$project_root/Tools/CLI" && run_cli_scenarios "messagepack"); then
            print_error "${SERVER_NAME} E2E scenarios ($variant) failed"
            show_logs "$SERVER_NAME" "messagepack"
            failed_encodings+=("$variant")
        elif ! sed $'s/\x1b\\[[0-9;]*m//g' "$variant_log" | grep -q "syncTables=off" \
            || sed $'s/\x1b\\[[0-9;]*m//g' "$variant_log" | grep -q "syncTables=on"; then
            print_error "${SERVER_NAME} ($variant): the server's lands did not all log syncTables=off"
            failed_encodings+=("$variant")
        else
            print_success "${SERVER_NAME} E2E scenarios ($variant) completed successfully"
        fi
    else
        print_error "Server failed to start for $variant"
        show_logs "$SERVER_NAME" "messagepack"
        failed_encodings+=("$variant")
    fi
    stop_server "$SERVER_NAME" "messagepack"
    unset USE_SYNC_TABLES TYPED_LEAF_VALUES
    echo ""
    
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
# shellcheck disable=SC2329  # invoked by the trap below
cleanup() {
    cleanup_servers "$SERVER_NAME" "json" "jsonOpcode" "messagepack"
}

trap cleanup EXIT INT TERM

# Run main function
main "$@"
