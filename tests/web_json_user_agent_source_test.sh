#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src_dir="$repo_root/src"

fail() {
    printf 'web_json_user_agent_source_test: %s\n' "$1" >&2
    exit 1
}

# The configured custom User-Agent belongs to a registered OAuth app. Wearing
# that identity on a request authenticated out of the web session makes Reddit 
# classify it as third-party Data API traffic; mature listings then collapse to
# the u/redditmaturecontent placeholder even with the account's 18+ preference
# enabled. Web-session requests must call ApolloWebJSONBrowserUserAgent() instead.
#
# The idiom for reading the custom setting, in every form used in the tree.
custom_ua_idiom='\[\?sUserAgent\(\.length\|[[:space:]]length\]\)[[:space:]]*>[[:space:]]*0[[:space:]]*?'

# Files allowed to set a Cookie header AND still read the custom setting. Each
# serves both transports and picks per request; adding a file here is a claim
# that its custom-UA branch is real OAuth traffic (a bearer issued to Apollo's
# own app), not a bearer minted from the web session.
allowed_mixed_transport="
src/ApolloWebJSON.m
src/ApolloUserFlair.xm
src/ApolloBadgeBookScraper.m
src/ApolloImageUploadHost.xm
"

cookie_files=$(cd "$repo_root" && grep -rl 'forHTTPHeaderField:@"Cookie"' src/ | sort)
custom_ua_files=$(cd "$repo_root" && grep -rl "$custom_ua_idiom" src/ | sort)

for file in $(printf '%s\n%s\n' "$cookie_files" "$custom_ua_files" | sort | uniq -d); do
    case "$allowed_mixed_transport" in
        *"
$file
"*) continue ;;
    esac
    fail "$file sets a Cookie header and reads the custom OAuth User-Agent; \
web-session requests must use ApolloWebJSONBrowserUserAgent()"
done

# Probe-marked requests bypass the transport chokepoint and set their own
# headers, so nothing can stamp the browser identity on their behalf. These
# keyless paths have each been audited to call the helper directly — a
# regression here puts the Dystopia UA back on cookie traffic.
for file in \
    src/ApolloWebJSON.m \
    src/ApolloTagFilters.xm \
    src/ApolloUserFlair.xm \
    src/ApolloImageUploadHost.xm
do
    grep -q 'ApolloWebJSONBrowserUserAgent()' "$repo_root/$file" ||
        fail "$file no longer calls ApolloWebJSONBrowserUserAgent()"
done

# The helper is shared across modules, so it has to stay exported; a stray
# `static` would silently push callers back onto their own hardcoded strings.
grep -q '^NSString \*ApolloWebJSONBrowserUserAgent(void);' "$repo_root/src/ApolloWebJSON.h" ||
    fail "ApolloWebJSONBrowserUserAgent() is not declared in src/ApolloWebJSON.h"

# Every Reddit-facing browser identity lives in ApolloWebJSON.m, so the tree
# stays on one desktop string and one mobile string instead of drifting into a
# handful of near-identical literals. Files below are allowed their own:
# Defaults.m holds the OAuth fallback and settings placeholder, and the rest
# talk to non-Reddit hosts where the UA is a deliberate per-host spoof (Redgifs
# binds its temp token to the exact minting UA; the AI summariser falls back to
# a crawler UA for SPA publishers).
allowed_own_ua="
src/ApolloWebJSON.m
src/Defaults.m
src/ApolloAISummary.xm
src/ApolloHostedVideo.m
src/ApolloImageChestResolver.m
src/ApolloInlineLinkPreviews.xm
src/ApolloLinkPreviewFetcher.m
src/ApolloShareAsVideo.xm
src/ApolloSportsClipResolver.m
"

for file in $(cd "$repo_root" && grep -rl '"Mozilla/5\.0' src/ | sort); do
    case "$allowed_own_ua" in
        *"
$file
"*) continue ;;
    esac
    fail "$file hardcodes its own browser User-Agent; Reddit-facing requests \
must call ApolloWebJSONBrowserUserAgent() or ApolloWebJSONMobileBrowserUserAgent()"
done

grep -q '^NSString \*ApolloWebJSONMobileBrowserUserAgent(void);' "$repo_root/src/ApolloWebJSON.h" ||
    fail "ApolloWebJSONMobileBrowserUserAgent() is not declared in src/ApolloWebJSON.h"

# Settings exposes a Web Session User Agent override, so the helper has to keep
# consulting it — pinning the helper back to a constant would leave a visible
# field that silently does nothing.
grep -q 'sWebSessionUserAgent' "$repo_root/src/ApolloWebJSON.m" ||
    fail "ApolloWebJSONBrowserUserAgent() no longer honours the sWebSessionUserAgent override"

# Web JSON itself keeps exactly one custom-UA branch: the real-OAuth arm of
# ApolloWebJSONFetchModernThingData, which talks to oauth.reddit.com with
# Apollo's own bearer.
web_json_custom_ua=$(grep -c "$custom_ua_idiom" "$repo_root/src/ApolloWebJSON.m" || true)
[ "$web_json_custom_ua" -eq 1 ] ||
    fail "expected one real-OAuth custom User-Agent branch in ApolloWebJSON.m, found $web_json_custom_ua"

printf 'web_json_user_agent_source_test passed\n'
