#!/bin/sh
# check-version-chain.sh — the three version links must agree.
#
#   .claude-plugin/plugin.json       .version
#   .claude-plugin/marketplace.json  .plugins[].version
#   skills/ping-pong/bin/pp          PP_VERSION
#
# Why this exists: `pp --version` is documented as the truth about which build
# you are running — that diagnostic is what tells a build with guards from one
# without. It has silently lied five times, whenever a release bumped the two
# manifests and left the constant in the script behind.
#
# Exit 0 = the three agree. Exit 1 = they disagree, or a link could not be read.
# The three values are printed either way: a silent pass reads exactly like a
# gate that never ran.
#
# What this is NOT: a release gate. It checks that the three links AGREE with
# each other, never that the number is the one this release should carry. All
# three can agree on an old version while the release should have bumped — and
# this passes. "OK" here means consistent, not ready to publish.
#
# Call it explicitly — there is no build step to hang it off. Either the
# enrichment step runs it before committing, or a human runs it before release.

set -u

# Resolves the repo from the script's own location, so it runs from any cwd.
# Caveat: invoked THROUGH a symlink placed elsewhere, $0 is the symlink and the
# root comes out wrong. It is meant to live inside the repo; if it is ever
# linked into a bin directory, resolve $0 with readlink -f first.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(dirname -- "$script_dir")

plugin_json="$repo/.claude-plugin/plugin.json"
market_json="$repo/.claude-plugin/marketplace.json"
pp_script="$repo/skills/ping-pong/bin/pp"

fail() { printf '%s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 ||
	fail "check-version-chain: jq not found. The gate cannot read its inputs, so it fails instead of guessing."

for f in "$plugin_json" "$market_json" "$pp_script"; do
	[ -r "$f" ] || fail "check-version-chain: cannot read $f"
done

v_plugin=$(jq -r '.version // empty' "$plugin_json" 2>/dev/null)
v_market=$(jq -r '[.plugins[].version] | unique | join(",")' "$market_json" 2>/dev/null)
v_script=$(sed -n 's/^PP_VERSION="\([^"]*\)".*/\1/p' "$pp_script" | head -n 1)

printf '  plugin.json        %s\n' "${v_plugin:-<unreadable>}"
printf '  marketplace.json   %s\n' "${v_market:-<unreadable>}"
printf '  bin/pp PP_VERSION  %s\n' "${v_script:-<unreadable>}"

[ -n "$v_plugin" ] && [ -n "$v_market" ] && [ -n "$v_script" ] ||
	fail "check-version-chain: FAIL — a version link is missing or unparseable."

if [ "$v_plugin" = "$v_market" ] && [ "$v_plugin" = "$v_script" ]; then
	printf 'check-version-chain: OK — the three links agree (%s).\n' "$v_plugin"
	exit 0
fi

printf 'check-version-chain: FAIL — the three links must move together.\n' >&2
printf 'Set all three to the release version, then re-run this check.\n' >&2
exit 1
