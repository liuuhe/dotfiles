#!/bin/bash
set -euo pipefail

rime_dir="$HOME/Library/Rime"
state_dir="$HOME/Library/Caches/rime-wanxiang"
mkdir -p "$rime_dir" "$state_dir"

# A successful check, including one with no updates, starts the next week.
if [[ "${1:-}" == --if-due && -f "$state_dir/last-check" ]]; then
  last_check="$(stat -f %m "$state_dir/last-check")"
  if (( $(date +%s) - last_check < 604800 )); then
    exit 0
  fi
fi

# Share one lock between manual restores and Hammerspoon's background task.
lock_dir="$state_dir/lock"
if [[ -f "$lock_dir/pid" ]] && ! kill -0 "$(cat "$lock_dir/pid")" 2>/dev/null; then
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
fi
mkdir "$lock_dir" 2>/dev/null || exit 0
printf '%s\n' "$$" > "$lock_dir/pid"
work_dir=""
cleanup() {
  [[ -z "$work_dir" ]] || rm -rf "$work_dir"
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work_dir="$(mktemp -d "$state_dir/update.XXXXXX")"

download() {
  curl --fail --location --silent --show-error --retry 2 \
    --connect-timeout 15 --max-time 1800 --output "$2" "$1"
}

# Find each release asset by name; LTS models can change without a new tag.
fetch_asset() {
  local api="$1" name="$2" marker="$3" index count asset_name url digest sha stored
  download "$api" "$work_dir/$name.json"
  count="$(plutil -extract assets raw -o - "$work_dir/$name.json")"
  for ((index = 0; index < count; index++)); do
    asset_name="$(plutil -extract "assets.$index.name" raw -o - "$work_dir/$name.json")"
    [[ "$asset_name" == "$name" ]] || continue
    url="$(plutil -extract "assets.$index.browser_download_url" raw -o - "$work_dir/$name.json")"
    digest="$(plutil -extract "assets.$index.digest" raw -o - "$work_dir/$name.json")"
    if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf 'Missing SHA256 for %s\n' "$name" >&2
      return 1
    fi
    sha="${digest#sha256:}"
    printf '%s\n' "$sha" > "$work_dir/$name.sha256"
    stored="$(cat "$state_dir/$name.sha256" 2>/dev/null || true)"
    if [[ "$stored" == "$sha" && -s "$rime_dir/$marker" ]]; then
      return 0
    fi
    # Adopt an already installed model without downloading it again.
    if [[ "$name" == *.gram && -f "$rime_dir/$name" ]] &&
      [[ "$(shasum -a 256 "$rime_dir/$name" | cut -d ' ' -f 1)" == "$sha" ]]; then
      return 0
    fi
    printf 'Downloading %s\n' "$name"
    download "$url" "$work_dir/$name"
    if [[ "$(shasum -a 256 "$work_dir/$name" | cut -d ' ' -f 1)" != "$sha" ]]; then
      printf 'SHA256 mismatch for %s\n' "$name" >&2
      return 1
    fi
    return 0
  done
  printf 'Release asset not found: %s\n' "$name" >&2
  return 1
}

lite=rime-wanxiang-lite.zip
model=wanxiang-lts-zh-hans.gram
fetch_asset https://api.github.com/repos/amzxyz/rime-wanxiang/releases/latest \
  "$lite" wanxiang_lite.schema.yaml
fetch_asset https://api.github.com/repos/amzxyz/RIME-LMDG/releases/tags/LTS \
  "$model" "$model"

# Finish both downloads before changing the installed configuration.
changed=false
if [[ -f "$work_dir/$lite" ]]; then
  unzip -q "$work_dir/$lite" -d "$work_dir/lite"
  test -s "$work_dir/lite/wanxiang_lite.schema.yaml"
  rsync -ac --exclude='*.custom.yaml' --exclude='*.userdb*' \
    --exclude='/custom_phrase.dict.yaml' "$work_dir/lite/" "$rime_dir/"
  if [[ ! -e "$rime_dir/custom_phrase.dict.yaml" && -f "$work_dir/lite/custom_phrase.dict.yaml" ]]; then
    cp "$work_dir/lite/custom_phrase.dict.yaml" "$rime_dir/"
  fi
  changed=true
fi
if [[ -f "$work_dir/$model" ]]; then
  mv -f "$work_dir/$model" "$rime_dir/$model"
  changed=true
fi

if "$changed"; then
  squirrel="/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
  if [[ -x "$squirrel" ]]; then
    "$squirrel" --reload
  fi
  printf 'Rime updated.\n'
else
  printf 'Rime is up to date.\n'
fi
mv -f "$work_dir/$lite.sha256" "$work_dir/$model.sha256" "$state_dir/"
touch "$state_dir/last-check"
