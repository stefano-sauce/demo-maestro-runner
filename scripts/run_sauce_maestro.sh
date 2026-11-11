#!/bin/bash
# Runs every Maestro flow in this repo on Sauce Labs (EU), once per provider-caps file.
# Each Sauce job is tagged so it is easy to find: repo:demo-maestro-runner, framework:maestro, ...
# Extra comma-separated tags can be passed in through $SAUCE_TAGS (the daily cron script does this).
#
# Usage: scripts/run_sauce_maestro.sh            # all targets
#        scripts/run_sauce_maestro.sh ios-simulator android-emulator   # only these caps files

REPO_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO_DIR" || exit 1

# Cron does not load the shell profile, so read the credentials from ~/.zshrc when they are missing.
zshrc_var() { sed -n "s/^export $1=//p" "$HOME/.zshrc" 2>/dev/null | tail -1 | tr -d "\"'"; }
for var in SAUCE_USERNAME SAUCE_ACCESS_KEY; do
    [ -z "${!var}" ] && export "$var=$(zshrc_var "$var")"
    [ -z "${!var}" ] && { echo "ERROR: $var is not set (export it in ~/.zshrc)."; exit 1; }
done
export PATH="/opt/homebrew/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

APPIUM_URL="https://$SAUCE_USERNAME:$SAUCE_ACCESS_KEY@ondemand.eu-central-1.saucelabs.com/wd/hub"
BASE_TAGS="repo:demo-maestro-runner,framework:maestro,cli:maestro-runner,lang:yaml,usecase:mobile-app"
[ -n "$SAUCE_TAGS" ] && BASE_TAGS="$BASE_TAGS,$SAUCE_TAGS"
# caps-file-name : flows folder : parallel sessions : device tag
# ARM emulators and the iOS 18.0 simulator time out creating a 3rd concurrent session, so they use 2.
# MAESTRO_PARALLEL overrides the value for every target.
TARGETS=(
    "android-real-device:flows/android:4:device:real-device"
    "android-emulator:flows/android:4:device:emulator"
    "android-arm-emulator:flows/android:2:device:arm-emulator"
    "ios-real-device:flows/ios:4:device:real-device"
    "ios-simulator:flows/ios:2:device:simulator"
)

# maestro-runner echoes the Appium URL (with the access key) in its log: mask it.
mask_key() { sed -u "s/$SAUCE_ACCESS_KEY/***/g"; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STATUS=0

for target in "${TARGETS[@]}"; do
    caps="${target%%:*}"; rest="${target#*:}"
    flows="${rest%%:*}"; rest="${rest#*:}"
    parallel="${MAESTRO_PARALLEL:-${rest%%:*}}"; device_tag="${rest#*:}"
    if [ $# -gt 0 ] && [[ ! " $* " == *" $caps "* ]]; then continue; fi

    tags="$BASE_TAGS,platform:${caps%%-*},$device_tag"
    tagged_caps="$TMP_DIR/$caps.json"
    # Add the tags to sauce:options without touching the checked-in caps file.
    jq --arg tags "$tags" '."sauce:options".tags = ($tags | split(","))' \
        "provider-caps/$caps.json" > "$tagged_caps" || { STATUS=1; continue; }

    echo "=== $caps ($flows) tags=$tags ==="
    if npx -y maestro-runner \
        --driver appium \
        --appium-url "$APPIUM_URL" \
        --caps "$tagged_caps" \
        --output "reports/$caps" \
        test --parallel "$parallel" "$flows/" 2>&1 | mask_key; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        echo "=== $caps: PASSED ==="
    else
        echo "=== $caps: FAILED ==="
        STATUS=1
    fi
    # The report folder keeps its own copy of the runner log: mask the key there too.
    grep -rl "$SAUCE_ACCESS_KEY" "reports/$caps" 2>/dev/null | while read -r f; do
        sed -i '' "s/$SAUCE_ACCESS_KEY/***/g" "$f"
    done
done

exit $STATUS
