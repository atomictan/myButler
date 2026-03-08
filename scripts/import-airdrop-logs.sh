#!/bin/zsh
set -euo pipefail
setopt null_glob

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target_dir="$repo_root/logs/airdrop"
mkdir -p "$target_dir"

patterns=(
  "voice-session-*.log"
  "voice-diff-*.json"
  "voice-items-*.json"
  "voice-monitor-*.json"
  "logs-debug-info-*.txt"
)

copied_count=0

for pattern in "${patterns[@]}"; do
  for file in "$HOME/Downloads"/${~pattern}; do
    [[ -e "$file" ]] || continue
    filename="${file:t}"
    if [[ ! -e "$target_dir/$filename" ]]; then
      cp "$file" "$target_dir/"
      ((copied_count+=1))
    fi
  done
done

if (( copied_count == 0 )); then
  echo "No new log files to copy to $target_dir"
else
  echo "Copied $copied_count log file(s) to $target_dir"
fi
