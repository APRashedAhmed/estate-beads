#!/usr/bin/env bash
# eb-root.sh / lib/eb_root.py (design §12.4): the installed-registry tier resolves the plugin's
# installPath from a fixture installed_plugins.json — the tier a vendored copy of this script,
# running inside another plugin's tree, needs to find estate-beads' OWN scripts. Both twins
# checked; stdout must be byte-identical (portability-contract.md §6).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A fake "installed" copy of the plugin (needs its own plugin.json so ownership checks pass).
fake_root="$tmp/fake-installed-root"
mkdir -p "$fake_root/.claude-plugin"
printf '{"name": "estate-beads"}' > "$fake_root/.claude-plugin/plugin.json"

cat > "$tmp/installed_plugins.json" <<JSON
{
  "plugins": {
    "estate-beads@homelab-plugins": [
      {"scope": "project", "installPath": "$fake_root-wrong-scope"},
      {"scope": "user", "installPath": "$fake_root"}
    ]
  }
}
JSON

# Force the ambient/env tiers to miss so resolution falls through to the registry tier.
unset EB_PLUGIN_ROOT PLUGIN_ROOT CLAUDE_PLUGIN_ROOT EB_WORKSPACE_SIBLING SEAT_ROOT 2>/dev/null

out_sh="$(EB_PLUGINS_JSON="$tmp/installed_plugins.json" bin/eb-root.sh --source plugin)"
assert_eq "bash twin: installed-registry tier prefers scope=user" \
  "$fake_root	installed-registry" "$out_sh"

out_py="$(EB_PLUGINS_JSON="$tmp/installed_plugins.json" python3 lib/eb_root.py --source plugin)"
assert_eq "python twin: installed-registry tier prefers scope=user" \
  "$fake_root	installed-registry" "$out_py"

assert_eq "both twins byte-identical on the registry tier" "$out_sh" "$out_py"

# Missing registry entry and no workspace sibling falls through to script-relative (still ours).
out_sh_fallback="$(EB_PLUGINS_JSON="$tmp/nonexistent.json" bin/eb-root.sh --source plugin)"
assert_contains "no registry hit falls to script-relative" "$out_sh_fallback" "script-relative"

# MINOR-2: the registry tier honours CLAUDE_CONFIG_DIR when EB_PLUGINS_JSON is not set.
config_dir="$tmp/alt-config"
mkdir -p "$config_dir/plugins"
cp "$tmp/installed_plugins.json" "$config_dir/plugins/installed_plugins.json"

out_sh_ccd="$(CLAUDE_CONFIG_DIR="$config_dir" bin/eb-root.sh --source plugin)"
assert_eq "bash twin: CLAUDE_CONFIG_DIR relocates the registry lookup" \
  "$fake_root	installed-registry" "$out_sh_ccd"

out_py_ccd="$(CLAUDE_CONFIG_DIR="$config_dir" python3 lib/eb_root.py --source plugin)"
assert_eq "python twin: CLAUDE_CONFIG_DIR relocates the registry lookup" \
  "$fake_root	installed-registry" "$out_py_ccd"

# MINOR-3: script-relative fallback must own the resolved root, else it's a hard failure —
# simulate this by running the twins from a copy of the tree relocated under a foreign name.
foreign_root="$tmp/foreign-copy"
mkdir -p "$foreign_root/bin" "$foreign_root/lib" "$foreign_root/.claude-plugin"
cp bin/eb-root.sh "$foreign_root/bin/eb-root.sh"
cp lib/eb_root.py "$foreign_root/lib/eb_root.py"
printf '{"name": "not-estate-beads"}' > "$foreign_root/.claude-plugin/plugin.json"

set +e
out_sh_unowned="$(EB_PLUGINS_JSON="$tmp/nonexistent.json" bash "$foreign_root/bin/eb-root.sh" plugin 2>&1)"
rc_sh_unowned=$?
set -e
assert_ne "bash twin: unowned script-relative fallback does not exit 0" "0" "$rc_sh_unowned"
assert_contains "bash twin: unowned fallback reports the mismatch" "$out_sh_unowned" "not"

set +e
out_py_unowned="$(EB_PLUGINS_JSON="$tmp/nonexistent.json" python3 "$foreign_root/lib/eb_root.py" plugin 2>&1)"
rc_py_unowned=$?
set -e
assert_ne "python twin: unowned script-relative fallback does not exit 0" "0" "$rc_py_unowned"
assert_contains "python twin: unowned fallback reports the mismatch" "$out_py_unowned" "not"

eb_report
