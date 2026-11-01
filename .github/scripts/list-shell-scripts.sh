#!/bin/bash
# Print every tracked shell script, NUL-separated: *.sh and *.bash, plus anything with a
# sh, bash or dash shebang whatever its name. Fails if it finds none, so that a broken
# search cannot look like a clean run.
set -euo pipefail
found=0
while IFS= read -r -d '' file; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  case "$file" in
    *.sh | *.bash) ;;
    *) head -n 1 -- "$file" | grep -qaE '^#!.*[/ ](ba|da)?sh( |$)' || continue ;;
  esac
  printf '%s\0' "$file"
  found=$((found + 1))
done < <(git ls-files -z)
[ "$found" -gt 0 ] || { echo "no shell scripts found" >&2; exit 1; }
echo "$found shell scripts" >&2
