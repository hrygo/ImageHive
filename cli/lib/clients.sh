#!/usr/bin/env bash
# MCP client wiring. Sourced, not run.
#
# Two rules, in order of preference:
#   1. If the client ships a `mcp add` command, use it — it owns its schema.
#   2. Otherwise edit the client's config: timestamped backup first, then our
#      own editor (cli/lib/*_edit.py), with a marker block `remove` can undo.

SV_SERVER_NAME="sensenova"
SV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sv_client_list() { printf '%s\n' codex claude opencode qwenpaw claude-desktop cursor; }

# Fills SV_ENV_PAIRS with the KEY=VALUE pairs every generated client entry
# needs. An array, not a word-split string: a home directory may contain spaces.
SV_ENV_PAIRS=()
sv_client_env_pairs() {
  SV_ENV_PAIRS=("SENSENOVA_HOME=$(sv_home)" "SENSENOVA_SERVED_BIN=$(sv_served)")
}

sv_client_detect() {
  case "$1" in
    codex)          sv_have codex ;;
    claude)         sv_have claude ;;
    opencode)       sv_have opencode || [ -f "$HOME/.config/opencode/opencode.jsonc" ] ;;
    qwenpaw)        [ -f "$HOME/.qwenpaw/config.json" ] ;;
    claude-desktop) [ -d "$HOME/Library/Application Support/Claude" ] ;;
    cursor)         [ -d "$HOME/.cursor" ] ;;
    *) return 1 ;;
  esac
}

sv_clients_detected() {
  local name
  for name in $(sv_client_list); do sv_client_detect "$name" && printf '%s\n' "$name"; done
  return 0
}

sv_client_config() {
  case "$1" in
    opencode)       printf '%s\n' "$HOME/.config/opencode/opencode.jsonc" ;;
    qwenpaw)        printf '%s\n' "$HOME/.qwenpaw/config.json" ;;
    claude-desktop) printf '%s\n' "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
    cursor)         printf '%s\n' "$HOME/.cursor/mcp.json" ;;
    *) return 1 ;;
  esac
}

sv_need_python() {
  sv_have python3 || die "python3 is required to edit MCP configs (run: xcode-select --install)"
}

sv_json_set() { # <file> <dotted-path> <command> [ENV=value ...]
  local file="$1"; shift
  sv_need_python
  local backup; backup="$(sv_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$SV_LIB_DIR/json_edit.py" set "$file" "$@"
}

# sv_json_set_client <file> <dotted-path> <flavor> <command> [ENV=value ...]
# `flavor` picks the entry shape a client expects (see json_edit.py).
sv_json_set_client() {
  local file="$1"; shift
  sv_need_python
  local backup; backup="$(sv_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$SV_LIB_DIR/json_edit.py" set-client "$file" "$@"
}

sv_json_unset() { # <file> <dotted-path>
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  sv_need_python
  local backup; backup="$(sv_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$SV_LIB_DIR/json_edit.py" unset "$file" "$path"
}

sv_json_has() { # <file> <dotted-path>
  [ -f "$1" ] || return 1
  sv_have python3 || return 1
  python3 "$SV_LIB_DIR/json_edit.py" has "$1" "$2"
}

sv_client_add() {
  local name="$1" mcp pair args=()
  mcp="$(sv_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  case "$name" in
    codex)
      sv_client_env_pairs
      for pair in "${SV_ENV_PAIRS[@]}"; do args+=(--env "$pair"); done
      codex mcp remove "$SV_SERVER_NAME" >/dev/null 2>&1 || true
      codex mcp add "$SV_SERVER_NAME" "${args[@]}" -- "$mcp" >/dev/null \
        && say "wired codex -> ~/.codex/config.toml"
      ;;
    claude)
      sv_client_env_pairs
      for pair in "${SV_ENV_PAIRS[@]}"; do args+=(-e "$pair"); done
      claude mcp remove "$SV_SERVER_NAME" -s user >/dev/null 2>&1 || true
      claude mcp add "$SV_SERVER_NAME" -s user "${args[@]}" -- "$mcp" >/dev/null \
        && say "wired claude (user scope)"
      ;;
    opencode)
      sv_need_python
      local file; file="$(sv_client_config opencode)"
      [ -f "$file" ] || die "$file not found — open opencode once, then re-run"
      local backup; backup="$(sv_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
      python3 "$SV_LIB_DIR/jsonc_edit.py" add "$file" "$mcp" "$(sv_home)" "$(sv_served)"
      say "wired opencode -> $file"
      ;;
    qwenpaw)
      sv_client_env_pairs
      sv_json_set_client "$(sv_client_config qwenpaw)" "mcp.clients.sensenova_image" qwenpaw "$mcp" "${SV_ENV_PAIRS[@]}"
      say "wired qwenpaw -> $(sv_client_config qwenpaw)"
      ;;
    claude-desktop)
      sv_client_env_pairs
      sv_json_set "$(sv_client_config claude-desktop)" "mcpServers.${SV_SERVER_NAME}" "$mcp" "${SV_ENV_PAIRS[@]}"
      say "wired claude-desktop (restart the app to pick it up)"
      ;;
    cursor)
      sv_client_env_pairs
      sv_json_set "$(sv_client_config cursor)" "mcpServers.${SV_SERVER_NAME}" "$mcp" "${SV_ENV_PAIRS[@]}"
      say "wired cursor -> $(sv_client_config cursor)"
      ;;
    generic) sv_print_snippet ;;
    *) die "unknown client: $name (known: $(sv_client_list | tr '\n' ' '))" ;;
  esac
}

sv_client_remove() {
  case "$1" in
    codex)
      codex mcp remove "$SV_SERVER_NAME" >/dev/null 2>&1 && say "unwired codex" \
        || hint "codex had no ${SV_SERVER_NAME} entry" ;;
    claude)
      claude mcp remove "$SV_SERVER_NAME" -s user >/dev/null 2>&1 && say "unwired claude" \
        || hint "claude had no ${SV_SERVER_NAME} entry" ;;
    opencode)
      local file; file="$(sv_client_config opencode)"
      local backup; backup="$(sv_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
      python3 "$SV_LIB_DIR/jsonc_edit.py" remove "$file" && say "unwired opencode" ;;
    qwenpaw)
      sv_json_unset "$(sv_client_config qwenpaw)" "mcp.clients.sensenova_image" && say "unwired qwenpaw" ;;
    claude-desktop)
      sv_json_unset "$(sv_client_config claude-desktop)" "mcpServers.${SV_SERVER_NAME}" && say "unwired claude-desktop" ;;
    cursor)
      sv_json_unset "$(sv_client_config cursor)" "mcpServers.${SV_SERVER_NAME}" && say "unwired cursor" ;;
    *) die "unknown client: $1" ;;
  esac
}

sv_client_has() {
  case "$1" in
    codex)  codex mcp get "$SV_SERVER_NAME" >/dev/null 2>&1 ;;
    claude) claude mcp get "$SV_SERVER_NAME" >/dev/null 2>&1 ;;
    opencode) python3 "$SV_LIB_DIR/jsonc_edit.py" has "$(sv_client_config opencode)" 2>/dev/null ;;
    qwenpaw) sv_json_has "$(sv_client_config qwenpaw)" "mcp.clients.sensenova_image" ;;
    claude-desktop) sv_json_has "$(sv_client_config claude-desktop)" "mcpServers.${SV_SERVER_NAME}" ;;
    cursor) sv_json_has "$(sv_client_config cursor)" "mcpServers.${SV_SERVER_NAME}" ;;
    *) return 1 ;;
  esac
}

sv_print_snippet() {
  cat <<EOF
Point your client at this stdio MCP server:

  command: $(sv_mcp)
  env:     SENSENOVA_HOME=$(sv_home)
           SENSENOVA_SERVED_BIN=$(sv_served)
EOF
}

# sv_client_add in a subshell: a hard failure for one client (a missing config,
# a client whose `mcp add` errors out) then costs that client only instead of
# aborting the whole install. The exit status is passed through.
sv_client_try() { ( sv_client_add "$1" ); }
