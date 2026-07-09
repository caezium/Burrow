#!/usr/bin/env bash
# Install (or uninstall) the Burrow-alerts launchd jobs for the current user.
#   ./launchd/install.sh          # generate + load both jobs
#   ./launchd/install.sh --uninstall
# Safe to re-run: it reloads the jobs from the current templates.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # the burrow-alerts dir
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
AGENTS="$HOME/Library/LaunchAgents"
LABELS=(dev.henryzh.burrow-alerts.check dev.henryzh.burrow-alerts.digest)

unload() {
  for L in "${LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$L" 2>/dev/null || true
    rm -f "$AGENTS/$L.plist"
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  unload
  echo "Uninstalled Burrow-alerts launchd jobs."
  exit 0
fi

if [[ ! -f "$DIR/config.local.json" ]]; then
  echo "⚠️  $DIR/config.local.json not found — the jobs won't have a recipient/creds." >&2
fi

mkdir -p "$AGENTS" "$DIR/logs"
unload   # clean slate

for TPL in "$DIR"/launchd/*.plist.template; do
  L="$(basename "$TPL" .plist.template)"
  OUT="$AGENTS/$L.plist"
  sed -e "s#__BUN__#$BUN#g" -e "s#__DIR__#$DIR#g" "$TPL" > "$OUT"
  plutil -lint "$OUT" >/dev/null
  launchctl bootstrap "gui/$(id -u)" "$OUT"
  echo "loaded $L"
done

echo
echo "Done. Jobs: check every 10 min, digest Sundays 09:00."
echo "Tail logs:   tail -f $DIR/logs/check.out.log"
echo "Run once now: launchctl kickstart -k gui/$(id -u)/dev.henryzh.burrow-alerts.check"
echo "Uninstall:    $DIR/launchd/install.sh --uninstall"
