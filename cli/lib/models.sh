#!/usr/bin/env bash
# Model artifact presets, download and verification. Sourced, not run.
#
# Artifacts are the ready-to-run MLX conversions published by the upstream
# project. They already contain tokenizer.json, so a fresh install needs no
# Python, no conversion step and no Hugging Face login.

# name|repo|tier|disk|peak|note
IH_PRESETS=(
  "fast-4bit|mlx-community/SenseNova-U1.5-8B-MoT-8step-4bit|fast|11 GiB|14.8 GB|8-step distilled, 4-bit — the default: fastest, smallest"
  "fast-8bit|mlx-community/SenseNova-U1.5-8B-MoT-8step-8bit|fast|20 GiB|22.4 GB|8-step distilled, 8-bit — closest to the bf16 draw of the fast tier"
  "quality-bf16|mlx-community/SenseNova-U1.5-8B-MoT-bf16|quality|33 GiB|35.1 GB|50-step reference tier, also the tier used for editing and VQA"
)

ih_preset_names() {
  local entry
  for entry in "${IH_PRESETS[@]}"; do printf '%s\n' "${entry%%|*}"; done
}

ih_preset_entry() {
  local wanted="$1" entry
  for entry in "${IH_PRESETS[@]}"; do
    [ "${entry%%|*}" = "$wanted" ] && { printf '%s\n' "$entry"; return 0; }
  done
  return 1
}

ih_preset_field() { # <preset> <1 repo|2 tier|3 disk|4 peak|5 note>
  local entry; entry="$(ih_preset_entry "$1")" || return 1
  printf '%s\n' "$entry" | awk -F'|' -v n="$2" '{print $n}'
}

ih_preset_repo() { ih_preset_field "$1" 2; }
ih_preset_tier() { ih_preset_field "$1" 3; }

ih_preset_dir() { # absolute artifact directory for a preset
  printf '%s\n' "$(ih_models)/$(ih_preset_repo "$1" | tr '/' '-')"
}

ih_require_python() {
  ih_have python3 || die "python3 is required for model downloads (install Xcode Command Line Tools: xcode-select --install)"
}

# --- source listing ----------------------------------------------------------
#
# Every listing prints "size<TAB>path" lines, skipping .gitattributes and the
# repo README (harmless but not part of the artifact).

ih_list_modelscope() {
  local repo="$1" json
  json="$(curl -fsSL "https://modelscope.cn/api/v1/models/${repo}/repo/files?Revision=master&Recursive=true")" \
    || die "could not list ${repo} on ModelScope"
  printf '%s' "$json" | python3 -c '
import json, sys
for f in json.load(sys.stdin)["Data"]["Files"]:
    path, size = f["Path"], f.get("Size", 0)
    if path.endswith(".gitattributes") or path.endswith("README.md"):
        continue
    print(f"{size}\t{path}")
'
}

ih_list_hf() {
  local repo="$1" endpoint="${2:-https://huggingface.co}" json
  json="$(curl -fsSL "${endpoint}/api/models/${repo}?blobs=true")" \
    || die "could not list ${repo} at ${endpoint}"
  printf '%s' "$json" | python3 -c '
import json, sys
for f in json.load(sys.stdin).get("siblings", []):
    path = f["rfilename"]
    if path.endswith(".gitattributes") or path.endswith("README.md"):
        continue
    print(f"{f.get('size', 0)}\t{path}")
'
}

ih_list_files() { # <repo> <source>
  case "$2" in
    modelscope) ih_list_modelscope "$1" ;;
    hf)         ih_list_hf "$1" "${HF_ENDPOINT:-https://huggingface.co}" ;;
    *)          die "unknown source: $2" ;;
  esac
}

ih_file_url() { # <repo> <path> <source>
  case "$3" in
    modelscope)
      python3 -c '
import sys, urllib.parse
repo, path = sys.argv[1], sys.argv[2]
print(f"https://modelscope.cn/api/v1/models/{repo}/repo?Revision=master&FilePath={urllib.parse.quote(path)}")
' "$1" "$2"
      ;;
    hf)
      printf '%s/%s/resolve/main/%s\n' "${HF_ENDPOINT:-https://huggingface.co}" "$1" "$2"
      ;;
  esac
}

# --- artifact state ----------------------------------------------------------

ih_model_ready() { # <dir> — a complete artifact we can hand to the daemon
  local dir="$1"
  [ -f "$dir/config.json" ] || return 1
  [ -f "$dir/tokenizer.json" ] || return 1
  [ -f "$dir/.manifest" ] || return 1
  return 0
}

ih_model_note() { # <dir>
  printf '%s\n' "$(cat "$1/.manifest" 2>/dev/null | awk -F= '$1=="repo"{print $2}')"
}

# --- download ----------------------------------------------------------------

ih_fetch_one() { # <url> <dest> <expected-size> <logfile>
  local url="$1" dest="$2" size="$3" log="$4" tmp="${2}.part"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && [ "$(stat -f%z "$dest" 2>/dev/null || echo 0)" = "$size" ]; then
    printf 'cached  %s\n' "$(basename "$dest")" >> "$log"
    return 0
  fi
  curl -fL --retry 5 --retry-delay 3 --retry-connrefused -C - \
    --connect-timeout 20 -o "$tmp" "$url" 2>>"$log" || return 1
  local got; got="$(stat -f%z "$tmp" 2>/dev/null || echo 0)"
  if [ "$size" != "0" ] && [ "$got" != "$size" ]; then
    printf 'size mismatch for %s: got %s want %s\n' "$(basename "$dest")" "$got" "$size" >> "$log"
    return 1
  fi
  mv "$tmp" "$dest"
  printf 'fetched %s\n' "$(basename "$dest")" >> "$log"
}

# ih_download_preset <preset> [source] [jobs]
ih_download_preset() {
  local preset="$1" source="${2:-auto}" jobs="${3:-3}"
  local repo dir
  repo="$(ih_preset_repo "$preset")" || die "unknown preset: $preset"
  dir="$(ih_preset_dir "$preset")"
  ih_require_python

  if ih_model_ready "$dir"; then
    hint "already installed: $preset ($(ih_dir_size "$dir"))"
    return 0
  fi

  local listing=""
  if [ "$source" = "auto" ] || [ "$source" = "modelscope" ]; then
    step "listing ${repo} on ModelScope"
    if listing="$(ih_list_modelscope "$repo" 2>/dev/null)" && [ -n "$listing" ]; then
      source="modelscope"
    else
      [ "$source" = "modelscope" ] && die "ModelScope has no ${repo}"
      hint "ModelScope listing failed, falling back to Hugging Face"
    fi
  fi
  if [ -z "$listing" ]; then
    source="hf"
    step "listing ${repo} on ${HF_ENDPOINT:-https://huggingface.co}"
    listing="$(ih_list_hf "$repo" "${HF_ENDPOINT:-https://huggingface.co}")"
  fi

  local count total_bytes
  count="$(printf '%s\n' "$listing" | grep -c . || true)"
  total_bytes="$(printf '%s\n' "$listing" | awk -F'\t' '{s+=$1} END{print s+0}')"
  say "$(printf '%s' "$listing" | awk -F'\t' '{printf "  %12d  %s\n", $1, $2}' | head -20)"
  say "  ${count} files, $(ih_human_bytes "$total_bytes") from ${source}"
  hint "  this can take a while; it is safe to interrupt and re-run — finished files are kept"

  mkdir -p "$dir"
  local log; log="$(mktemp)"
  # A multi-gigabyte download that prints nothing reads as "it hung". Poll the
  # directory from a background loop instead: it costs one `du` every few
  # seconds and stops with the fetches below.
  local hb="" hb_interval=10
  [ -t 2 ] || hb_interval=60
  if [ "${IMAGEHIVE_PROGRESS:-1}" != "0" ]; then
    ih_progress_loop "$dir" "$total_bytes" "$count" "$log" "$hb_interval" &
    hb=$!
  fi

  local failed=0 group=0 pids=()
  while IFS=$'\t' read -r size path; do
    [ -n "$path" ] || continue
    ih_fetch_one "$(ih_file_url "$repo" "$path" "$source")" "$dir/$path" "$size" "$log" &
    pids+=($!)
    group=$((group + 1))
    if [ "$group" -ge "$jobs" ]; then
      # Wait for the fetches only: a bare `wait` would also wait for the
      # progress loop, which never exits on its own.
      if [ "${#pids[@]}" -gt 0 ]; then
        wait "${pids[@]}" || true
        pids=()
      fi
      grep -q 'failed\|mismatch' "$log" 2>/dev/null && failed=1
      group=0
    fi
  done <<< "$listing"
  if [ "${#pids[@]}" -gt 0 ]; then
    wait "${pids[@]}" || true
    pids=()
  fi
  if [ -n "$hb" ]; then
    kill "$hb" 2>/dev/null || true
    wait "$hb" 2>/dev/null || true
  fi

  local bad
  bad="$(grep -c 'mismatch' "$log" 2>/dev/null || true)"
  grep -q 'mismatch' "$log" 2>/dev/null && failed=1
  tail -20 "$log" >&2
  rm -f "$log"
  [ "$failed" = "0" ] || die "download failed (${bad} size mismatches) — re-run to resume"

  printf 'repo=%s\nsource=%s\nrevision=%s\n' "$repo" "$source" "master" > "$dir/.manifest"
  printf '%s\n' "$listing" | awk -F'\t' '{printf "size=%s\tpath=%s\n", $1, $2}' >> "$dir/.manifest"
  say "installed ${preset} -> ${dir} ($(ih_dir_size "$dir"))"
}

# ih_progress_loop <dir> <total-bytes> <total-files> <log> <seconds>
# Prints one line per tick until it is killed. Never fails the installer: a
# missing directory or an unreadable log just means this tick prints less.
ih_progress_loop() {
  local dir="$1" total="$2" files="$3" log="$4" tick="$5"
  local start now done_bytes done_files elapsed
  start="$(date +%s)"
  while :; do
    sleep "$tick" || return 0
    done_bytes="$(du -sk "$dir" 2>/dev/null | awk '{print $1 * 1024}' || true)"
    done_files="$(grep -c -e '^fetched' -e '^cached' "$log" 2>/dev/null || true)"
    now="$(date +%s)"
    elapsed=$((now - start))
    [ "$elapsed" -gt 0 ] || elapsed=1
    printf '%s  %s/%s files, %s of %s (%s%%), %s elapsed\n' \
      "$IH_DIM" "${done_files:-0}" "$files" \
      "$(ih_human_bytes "${done_bytes:-0}")" "$(ih_human_bytes "$total")" \
      "$(ih_percent "${done_bytes:-0}" "$total")" "$(ih_human_seconds "$elapsed")" >&2
  done
}

# ih_human_bytes <bytes> — "33.0 GiB"
ih_human_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " ")
    n = 1
    while (b >= 1024 && n < 5) { b /= 1024; n++ }
    printf (n == 1 ? "%.0f %s" : "%.1f %s"), b, unit[n]
  }'
}

# ih_percent <done-bytes> <total-bytes> — integer, 0 when the total is unknown
ih_percent() {
  local done="${1:-0}" total="${2:-0}"
  [ "${total:-0}" -gt 0 ] 2>/dev/null || { printf '?\n'; return 0; }
  printf '%s\n' "$((done * 100 / total))"
}

# ih_human_seconds <seconds> — "4m30s"
ih_human_seconds() {
  local s="${1:-0}"
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm\n' "$((s / 3600))" "$(((s % 3600) / 60))"
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds\n' "$((s / 60))" "$((s % 60))"
  else printf '%ds\n' "$s"; fi
}

# ih_verify_preset <preset> — sizes on disk vs what the manifest recorded
ih_verify_preset() {
  local dir; dir="$(ih_preset_dir "$1")"
  ih_model_ready "$dir" || { warn "not installed: $1"; return 1; }
  local bad=0
  while IFS=$'\t' read -r spec path; do
    local want="${spec#size=}" got
    got="$(stat -f%z "$dir/$path" 2>/dev/null || echo 0)"
    [ "$got" = "$want" ] || { warn "size mismatch: $path (disk $got, expected $want)"; bad=1; }
  done < <(grep '^size=' "$dir/.manifest")
  [ "$bad" = "0" ] || return 1
  return 0
}
