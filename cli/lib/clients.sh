#!/usr/bin/env bash
# MCP client wiring. Sourced, not run.
#
# Two rules, in order of preference:
#   1. If the client ships a `mcp add` command, use it — it owns its schema.
#   2. Otherwise edit the client's config: timestamped backup first, then our
#      own editor (cli/lib/*_edit.py), with a marker block `remove` can undo.

IH_SERVER_NAME="imagehive"
# The pre-0.6 name, wherever it was written. Removing it is not tidiness: both
# entries expose the same six tools, so a client that keeps the old one shows
# every tool twice — and the old one points at paths the rename moved.
IH_LEGACY_SERVER_NAME="sensenova"
IH_LEGACY_QWENPAW_KEY="mcp.clients.sensenova_image"
IH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ih_client_list() { printf '%s\n' codex claude opencode qwenpaw claude-desktop cursor; }

# Fills IH_ENV_PAIRS with the KEY=VALUE pairs every generated client entry
# needs. An array, not a word-split string: a path may contain spaces. Models
# and output are pinned only when they differ from what the app home implies,
# so a normal install gets a two-line entry and a custom layout still works.
IH_ENV_PAIRS=()
ih_client_env_pairs() {
  IH_ENV_PAIRS=("IMAGEHIVE_HOME=$(ih_home)" "IMAGEHIVE_DAEMON_BIN=$(ih_daemon)")
  [ "$(ih_models)" = "$(ih_home)/models" ] || IH_ENV_PAIRS+=("IMAGEHIVE_MODELS=$(ih_models)")
  [ "$(ih_out_dir)" = "$IH_DEFAULT_OUT" ] || IH_ENV_PAIRS+=("IMAGEHIVE_OUT=$(ih_out_dir)")
}

ih_client_detect() {
  case "$1" in
    codex)          ih_have codex ;;
    claude)         ih_have claude ;;
    opencode)       ih_have opencode || [ -f "$HOME/.config/opencode/opencode.jsonc" ] ;;
    qwenpaw)        [ -f "$HOME/.qwenpaw/config.json" ] ;;
    claude-desktop) [ -d "$HOME/Library/Application Support/Claude" ] ;;
    cursor)         [ -d "$HOME/.cursor" ] ;;
    *) return 1 ;;
  esac
}

ih_clients_detected() {
  local name
  for name in $(ih_client_list); do ih_client_detect "$name" && printf '%s\n' "$name"; done
  return 0
}

ih_client_config() {
  case "$1" in
    opencode)       printf '%s\n' "$HOME/.config/opencode/opencode.jsonc" ;;
    qwenpaw)        printf '%s\n' "$HOME/.qwenpaw/config.json" ;;
    claude-desktop) printf '%s\n' "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
    cursor)         printf '%s\n' "$HOME/.cursor/mcp.json" ;;
    *) return 1 ;;
  esac
}

ih_need_python() {
  ih_have python3 || die "python3 is required to edit MCP configs (run: xcode-select --install)"
}

ih_json_set() { # <file> <dotted-path> <command> [ENV=value ...]
  local file="$1"; shift
  ih_need_python
  local backup; backup="$(ih_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$IH_LIB_DIR/json_edit.py" set "$file" "$@"
}

# ih_json_set_client <file> <dotted-path> <flavor> <command> [ENV=value ...]
# `flavor` picks the entry shape a client expects (see json_edit.py).
ih_json_set_client() {
  local file="$1"; shift
  ih_need_python
  local backup; backup="$(ih_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$IH_LIB_DIR/json_edit.py" set-client "$file" "$@"
}

ih_json_unset() { # <file> <dotted-path>
  local file="$1" path="$2"
  [ -f "$file" ] || return 0
  ih_need_python
  local backup; backup="$(ih_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
  python3 "$IH_LIB_DIR/json_edit.py" unset "$file" "$path"
}

ih_json_has() { # <file> <dotted-path>
  [ -f "$1" ] || return 1
  ih_have python3 || return 1
  python3 "$IH_LIB_DIR/json_edit.py" has "$1" "$2"
}

ih_client_add() {
  local name="$1" mcp pair args=()
  mcp="$(ih_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  case "$name" in
    codex)
      ih_client_env_pairs
      for pair in "${IH_ENV_PAIRS[@]}"; do args+=(--env "$pair"); done
      codex mcp remove "$IH_SERVER_NAME" >/dev/null 2>&1 || true
      codex mcp add "$IH_SERVER_NAME" "${args[@]}" -- "$mcp" >/dev/null \
        && say "wired codex -> ~/.codex/config.toml"
      ;;
    claude)
      ih_client_env_pairs
      for pair in "${IH_ENV_PAIRS[@]}"; do args+=(-e "$pair"); done
      claude mcp remove "$IH_SERVER_NAME" -s user >/dev/null 2>&1 || true
      claude mcp add "$IH_SERVER_NAME" -s user "${args[@]}" -- "$mcp" >/dev/null \
        && say "wired claude (user scope)"
      ;;
    opencode)
      ih_need_python
      local file; file="$(ih_client_config opencode)"
      [ -f "$file" ] || die "$file not found — open opencode once, then re-run"
      local backup; backup="$(ih_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
      python3 "$IH_LIB_DIR/jsonc_edit.py" add "$file" "$mcp" "$(ih_home)" "$(ih_daemon)"
      say "wired opencode -> $file"
      ;;
    qwenpaw)
      ih_client_env_pairs
      ih_json_set_client "$(ih_client_config qwenpaw)" "mcp.clients.imagehive_image" qwenpaw "$mcp" "${IH_ENV_PAIRS[@]}"
      say "wired qwenpaw -> $(ih_client_config qwenpaw)"
      ;;
    claude-desktop)
      ih_client_env_pairs
      ih_json_set "$(ih_client_config claude-desktop)" "mcpServers.${IH_SERVER_NAME}" "$mcp" "${IH_ENV_PAIRS[@]}"
      say "wired claude-desktop (restart the app to pick it up)"
      ;;
    cursor)
      ih_client_env_pairs
      ih_json_set "$(ih_client_config cursor)" "mcpServers.${IH_SERVER_NAME}" "$mcp" "${IH_ENV_PAIRS[@]}"
      say "wired cursor -> $(ih_client_config cursor)"
      ;;
    generic) ih_print_snippet ;;
    *) die "unknown client: $name (known: $(ih_client_list | tr '\n' ' '))" ;;
  esac
  # Wiring a client is a statement about *that* client, so an entry left under the
  # pre-0.6 name goes with it: both entries expose the same six tools, and a client
  # that keeps the old one lists every tool twice.
  case "$name" in
    generic) ;;
    *) ih_client_remove_legacy "$name" ;;
  esac
}

ih_client_remove() {
  case "$1" in
    codex)
      codex mcp remove "$IH_SERVER_NAME" >/dev/null 2>&1 && say "unwired codex" \
        || hint "codex had no ${IH_SERVER_NAME} entry" ;;
    claude)
      claude mcp remove "$IH_SERVER_NAME" -s user >/dev/null 2>&1 && say "unwired claude" \
        || hint "claude had no ${IH_SERVER_NAME} entry" ;;
    opencode)
      local file; file="$(ih_client_config opencode)"
      local backup; backup="$(ih_backup "$file")"; [ -n "$backup" ] && hint "backup: $backup"
      python3 "$IH_LIB_DIR/jsonc_edit.py" remove "$file" && say "unwired opencode" ;;
    qwenpaw)
      ih_json_unset "$(ih_client_config qwenpaw)" "mcp.clients.imagehive_image" && say "unwired qwenpaw" ;;
    claude-desktop)
      ih_json_unset "$(ih_client_config claude-desktop)" "mcpServers.${IH_SERVER_NAME}" && say "unwired claude-desktop" ;;
    cursor)
      ih_json_unset "$(ih_client_config cursor)" "mcpServers.${IH_SERVER_NAME}" && say "unwired cursor" ;;
    *) die "unknown client: $1" ;;
  esac
  # Both names go: an entry left under the pre-0.6 name keeps the client wired —
  # it starts the new daemon through the compatibility wrapper — so a `remove`
  # that only deleted the new one would not do what it says.
  ih_client_remove_legacy
}

ih_client_has() {
  case "$1" in
    codex)  codex mcp get "$IH_SERVER_NAME" >/dev/null 2>&1 ;;
    claude) claude mcp get "$IH_SERVER_NAME" >/dev/null 2>&1 ;;
    opencode) python3 "$IH_LIB_DIR/jsonc_edit.py" has "$(ih_client_config opencode)" 2>/dev/null ;;
    qwenpaw) ih_json_has "$(ih_client_config qwenpaw)" "mcp.clients.imagehive_image" ;;
    claude-desktop) ih_json_has "$(ih_client_config claude-desktop)" "mcpServers.${IH_SERVER_NAME}" ;;
    cursor) ih_json_has "$(ih_client_config cursor)" "mcpServers.${IH_SERVER_NAME}" ;;
    *) return 1 ;;
  esac
}

# True when this client still carries an entry under the pre-0.6 name. `doctor`
# asks, so a half-migrated client is reported instead of showing up as duplicate
# tools an agent cannot explain.
ih_client_has_legacy() {
  case "$1" in
    codex)  codex mcp get "$IH_LEGACY_SERVER_NAME" >/dev/null 2>&1 ;;
    claude) claude mcp get "$IH_LEGACY_SERVER_NAME" >/dev/null 2>&1 ;;
    opencode) python3 "$IH_LIB_DIR/jsonc_edit.py" has-legacy "$(ih_client_config opencode)" 2>/dev/null ;;
    qwenpaw) ih_json_has "$(ih_client_config qwenpaw)" "$IH_LEGACY_QWENPAW_KEY" ;;
    claude-desktop) ih_json_has "$(ih_client_config claude-desktop)" "mcpServers.${IH_LEGACY_SERVER_NAME}" ;;
    cursor) ih_json_has "$(ih_client_config cursor)" "mcpServers.${IH_LEGACY_SERVER_NAME}" ;;
    *) return 1 ;;
  esac
}

# Drops the pre-0.6 entry — from every client that is installed here, or from the
# one named — and says which clients it changed. Safe to re-run: each branch only
# acts when the entry is actually there, so no config is rewritten (and
# reformatted) for nothing.
ih_client_remove_legacy() { # [client]
  local name changed=0
  local names="${1:-$(ih_client_list)}"
  for name in $names; do
    ih_client_detect "$name" || continue
    ih_client_has_legacy "$name" || continue
    case "$name" in
      codex)
        codex mcp remove "$IH_LEGACY_SERVER_NAME" >/dev/null 2>&1 || continue ;;
      claude)
        claude mcp remove "$IH_LEGACY_SERVER_NAME" -s user >/dev/null 2>&1 || continue ;;
      opencode)
        python3 "$IH_LIB_DIR/jsonc_edit.py" remove "$(ih_client_config opencode)" || continue ;;
      qwenpaw)
        ih_json_unset "$(ih_client_config qwenpaw)" "$IH_LEGACY_QWENPAW_KEY" || continue ;;
      claude-desktop)
        ih_json_unset "$(ih_client_config claude-desktop)" "mcpServers.${IH_LEGACY_SERVER_NAME}" || continue ;;
      cursor)
        ih_json_unset "$(ih_client_config cursor)" "mcpServers.${IH_LEGACY_SERVER_NAME}" || continue ;;
      *) continue ;;
    esac
    say "removed the pre-0.6 ${IH_LEGACY_SERVER_NAME} entry from $name"
    changed=1
  done
  [ "$changed" = "0" ] || hint "     (that entry pointed at the old paths; the new one is ${IH_SERVER_NAME})"
  return 0
}

ih_print_snippet() {
  ih_client_env_pairs
  printf 'Point your client at this stdio MCP server:\n\n  command: %s\n  env:\n' "$(ih_mcp)"
  local pair
  for pair in "${IH_ENV_PAIRS[@]}"; do printf '    %s\n' "$pair"; done
}

# ih_client_add in a subshell: a hard failure for one client (a missing config,
# a client whose `mcp add` errors out) then costs that client only instead of
# aborting the whole install. The exit status is passed through.
ih_client_try() { ( ih_client_add "$1" ); }
