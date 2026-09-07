#!/usr/bin/env bash
# Common argument parser for the normalized mesh CLI.

mesh_parse_args() {
    MESH_CLI_COMMAND=""
    MESH_CLI_NODE=""
    MESH_CLI_INVENTORY="${INVENTORY:-$MESH_DIR/inventory.json}"
    MESH_CLI_DRY_RUN=0
    MESH_CLI_YES=0
    MESH_CLI_NON_INTERACTIVE=0
    MESH_CLI_TIMEOUT=120
    MESH_CLI_VERBOSE=0
    MESH_CLI_OUTPUT=""
    MESH_CLI_POSITIONAL=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --inventory) [ $# -ge 2 ] || { error "--inventory requires a path"; return 1; }; MESH_CLI_INVENTORY="$2"; shift 2 ;;
            --node) [ $# -ge 2 ] || { error "--node requires a name"; return 1; }; MESH_CLI_NODE="$2"; shift 2 ;;
            --timeout) [ $# -ge 2 ] || { error "--timeout requires seconds"; return 1; }; MESH_CLI_TIMEOUT="$2"; shift 2 ;;
            --output) [ $# -ge 2 ] || { error "--output requires a directory"; return 1; }; MESH_CLI_OUTPUT="$2"; shift 2 ;;
            --dry-run) MESH_CLI_DRY_RUN=1; shift ;;
            --yes) MESH_CLI_YES=1; shift ;;
            --non-interactive) MESH_CLI_NON_INTERACTIVE=1; shift ;;
            --verbose) MESH_CLI_VERBOSE=1; shift ;;
            --) shift; while [ $# -gt 0 ]; do MESH_CLI_POSITIONAL+=("$1"); shift; done ;;
            -*) error "unknown option: $1"; return 1 ;;
            *)
                if [ -z "$MESH_CLI_COMMAND" ]; then MESH_CLI_COMMAND="$1"; else MESH_CLI_POSITIONAL+=("$1"); fi
                shift
                ;;
        esac
    done

    [[ "$MESH_CLI_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { error "--timeout must be a positive integer"; return 1; }
    [ -n "$MESH_CLI_COMMAND" ] || { error "command required"; return 1; }

    INVENTORY="$MESH_CLI_INVENTORY"
    MESH_TIMEOUT="$MESH_CLI_TIMEOUT"
    MESH_YES="$MESH_CLI_YES"
    MESH_NON_INTERACTIVE="$MESH_CLI_NON_INTERACTIVE"
    MESH_VERBOSE="$MESH_CLI_VERBOSE"
    export INVENTORY MESH_TIMEOUT MESH_YES MESH_NON_INTERACTIVE MESH_VERBOSE
    export MESH_CLI_COMMAND MESH_CLI_NODE MESH_CLI_INVENTORY MESH_CLI_DRY_RUN
    export MESH_CLI_YES MESH_CLI_NON_INTERACTIVE MESH_CLI_TIMEOUT MESH_CLI_VERBOSE MESH_CLI_OUTPUT
}

mesh_require_node() {
    [ -n "$MESH_CLI_NODE" ] || { error "--node is required"; return 1; }
}

mesh_guard_non_interactive_change() {
    if [ "$MESH_CLI_NON_INTERACTIVE" -eq 1 ] && [ "$MESH_CLI_YES" -ne 1 ]; then
        error "--non-interactive state changes require --yes"
        return 1
    fi
}
