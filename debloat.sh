#!/usr/bin/env bash
# ============================================================
# POCO X3 Pro (vayu) - Debloat script
# ============================================================
# Removes known-safe bloat from a POCO X3 Pro running MIUI 14 / Android 13.
# Method: pm uninstall -k --user 0  (reversible, no root, no bootloader unlock)
#
# Usage:
#   bash debloat.sh             # interactive (explains + prompts per package)
#   bash debloat.sh --yes       # non-interactive, removes all batches
#   bash debloat.sh --list      # only list what would be removed, do nothing
#   bash debloat.sh --batch 2   # only run batch N (1-5)
#
# Each removed package is appended to removed_packages.txt in the same
# folder as this script. Pair with restore.sh to undo.
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backup"
LOG_FILE="${BACKUP_DIR}/removed_packages.txt"
INTERACTIVE=1
LIST_ONLY=0
BATCH_FILTER=""

# Colors
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

# ---------- Pre-flight checks ----------
check_device() {
  if ! command -v adb >/dev/null 2>&1; then
    echo "${C_RED}ERROR: adb not found in PATH${C_RESET}" >&2
    exit 1
  fi
  if ! adb devices 2>/dev/null </dev/null | grep -q '\bdevice$'; then
    echo "${C_RED}ERROR: no adb device connected.${C_RESET}" >&2
    echo "Run 'adb devices' to check. Make sure USB debugging is on and the phone is authorized." >&2
    exit 1
  fi
  echo "${C_GREEN}Device connected:${C_RESET} $(adb shell getprop ro.product.model </dev/null) ($(adb shell getprop ro.product.name </dev/null))"
  echo "ROM: $(adb shell getprop ro.build.fingerprint </dev/null)"
  echo ""
}

# ---------- Get RAM usage of a package (if running) ----------
get_ram_usage() {
  local pkg="$1"
  local pid
  pid=$(adb shell "pidof $pkg 2>/dev/null" </dev/null | tr -d '\r' | head -1)
  if [ -z "$pid" ]; then
    echo ""
  else
    local pss
    pss=$(adb shell "dumpsys meminfo $pid 2>/dev/null | grep 'TOTAL PSS' | head -1" </dev/null | awk '{print $3}' | tr -d '\r')
    if [ -n "$pss" ]; then
      local mb=$((pss / 1024))
      echo "${mb} MB RAM"
    else
      echo "running"
    fi
  fi
}

# ---------- Append a batch to the removal log ----------
log_batch() {
  local batch_name="$1"; shift
  {
    echo ""
    echo "# $(date +%F) - ${batch_name}"
    for p in "$@"; do echo "$p"; done
  } >> "$LOG_FILE"
}

# ---------- Remove one package ----------
# Returns: 0 = removed, 1 = failed, 2 = skipped (already removed/not installed)
remove_pkg() {
  local pkg="$1"
  if ! adb shell pm path "$pkg" 2>/dev/null </dev/null | grep -q apk; then
    echo "  ${C_YELLOW}SKIP${C_RESET}  $pkg (not installed)"
    return 2
  fi
  if ! adb shell pm list packages --user 0 2>/dev/null </dev/null | grep -q "^package:${pkg}$"; then
    echo "  ${C_YELLOW}SKIP${C_RESET}  $pkg (already removed for user 0)"
    return 2
  fi
  local out
  out=$(adb shell pm uninstall -k --user 0 "$pkg" 2>&1 </dev/null)
  if echo "$out" | grep -q 'Success'; then
    echo "  ${C_GREEN}OK${C_RESET}    $pkg"
    return 0
  else
    echo "  ${C_RED}FAIL${C_RESET}  $pkg -> $out"
    return 1
  fi
}

# ---------- Display a package card ----------
# Format: "pkg|what|details|why|caveats"
# Sets CARD_RAM global with RAM usage string (or empty) for option labels
show_pkg_card() {
  local entry="$1"
  local pkg what details why caveats
  IFS='|' read -r pkg what details why caveats <<< "$entry"
  CARD_RAM=$(get_ram_usage "$pkg")
  echo ""
  echo "  ${C_BOLD}Package:${C_RESET}  $pkg"
  echo "  ${C_BOLD}What:${C_RESET}     $what"
  if [ -n "$details" ]; then
    echo "  ${C_BOLD}Details:${C_RESET} $details"
  fi
  echo "  ${C_BOLD}Why:${C_RESET}      $why"
  if [ -n "$caveats" ]; then
    echo "  ${C_BOLD}Caveats:${C_RESET}  $caveats"
  fi
  if [ -n "$CARD_RAM" ]; then
    echo "  ${C_BOLD}Now:${C_RESET}      ${C_YELLOW}${CARD_RAM}${C_RESET}"
  fi
}

# ---------- Run a batch ----------
# Args: batch_num batch_name pkg1|desc1|why1 pkg2|desc2|why2 ...
run_batch() {
  local num="$1"; local name="$2"; shift 2
  local entries=("$@")
  echo ""
  echo "${C_CYAN}${C_BOLD}=== Batch $num: $name (${#entries[@]} packages) ===${C_RESET}"

  if [ "$LIST_ONLY" = "1" ]; then
    for e in "${entries[@]}"; do
      local pkg what
      IFS='|' read -r pkg what _ _ _ <<< "$e"
      echo "  would remove: $pkg  ${C_DIM}($what)${C_RESET}"
    done
    echo ""
    return 0
  fi

  if [ "$INTERACTIVE" = "1" ]; then
    echo ""
    echo "${C_DIM}For each package, you'll see what it is, why it's being removed, and"
    echo "current RAM usage. Then choose: 1 (remove), 2 (keep), or 3 (skip batch).${C_RESET}"
  fi

  local removed=()
  local skipped=0
  for e in "${entries[@]}"; do
    local pkg
    IFS='|' read -r pkg _ _ _ _ <<< "$e"

    if [ "$INTERACTIVE" = "1" ]; then
      show_pkg_card "$e"
      local opt1_label="Remove"
      if [ -n "${CARD_RAM:-}" ]; then
        opt1_label="Remove (frees ${CARD_RAM})"
      fi
      echo ""
      echo "  ${C_BOLD}1)${C_RESET} ${opt1_label}"
      echo "  ${C_BOLD}2)${C_RESET} Keep"
      echo "  ${C_BOLD}3)${C_RESET} Skip rest of this batch"
      while true; do
        printf "  ${C_BOLD}Choose [1-3] (default 2):${C_RESET} "
        read -r ans
        case "$ans" in
          1|remove|Remove|REMOVE)
            remove_pkg "$pkg"
            rc=$?
            if [ "$rc" = "0" ]; then removed+=("$pkg"); fi
            break
            ;;
          3|skip|Skip|SKIP|s|S)
            echo "  ${C_DIM}Skipping rest of batch $num.${C_RESET}"
            skipped=1
            break 2
            ;;
          2|keep|Keep|KEEP|n|N|no|NO|"")
            echo "  ${C_DIM}Kept: $pkg${C_RESET}"
            break
            ;;
          *)
            echo "  ${C_DIM}Please choose 1 (remove), 2 (keep), or 3 (skip rest of batch).${C_RESET}"
            ;;
        esac
      done
    else
      remove_pkg "$pkg"
      if [ "$?" = "0" ]; then removed+=("$pkg"); fi
    fi
  done

  if [ "${#removed[@]}" -gt 0 ]; then
    log_batch "Batch $num: $name" "${removed[@]}"
  fi

  echo ""
  if [ "$skipped" = "1" ] && [ "$INTERACTIVE" = "1" ]; then
    echo "${C_YELLOW}Batch $num partially done.${C_RESET} Removed ${#removed[@]} package(s)."
  else
    echo "${C_GREEN}Batch $num done.${C_RESET} Removed ${#removed[@]} of ${#entries[@]} package(s)."
  fi
  if [ "${#removed[@]}" -gt 0 ]; then
    echo "${C_YELLOW}Test the phone now (unlock, Settings, launcher, reboot).${C_RESET}"
    echo "If broken: bash ${SCRIPT_DIR}/restore.sh ${removed[*]}"
  fi
  echo ""
}

# ---------- Batch definitions ----------
# Format: "package|what|details|why|caveats"

BATCH1=(
  "com.miui.analytics|Xiaomi Analytics|Collects app usage patterns, feature usage, crash stats, and device telemetry. Uploads to Xiaomi servers. Runs in background.|Stops usage pattern reporting to Xiaomi. Privacy win.|Safe to remove. No user-facing functionality breaks."
  "com.miui.systemAdSolution|Xiaomi Ad SDK (MSA equivalent)|Xiaomi's system ad solution. Injects ads into Notification shade, Settings, Security Center, and other Xiaomi apps. The biggest source of in-OS ads on MIUI 14. Persistent background service.|Biggest privacy and UX win. Removes ads from the entire OS. Stops ad-targeting data collection.|Safe to remove. No system functionality breaks. Ads simply stop appearing."
  "com.miui.misightservice|Xiaomi MiSight (insights/telemetry)|Xiaomi's insights and telemetry service. Collects device health, feature usage, system metrics. Phones home to Xiaomi.|Same telemetry category as Joyose. Stops another telemetry channel.|Safe to remove. No user-facing functionality breaks."
  "com.xiaomi.joyose|Xiaomi Joyose (telemetry + Game Turbo)|Background service handling usage analytics, device health reporting, and Game Turbo backend. Phones home with usage patterns and performance metrics.|Stops Xiaomi usage analytics and telemetry. Reclaim background CPU and RAM.|Removing disables Game Turbo advanced features (per-game GPU/CPU tuning, brightness lock, calls blocking during games). Basic gaming still works fine."
  "com.miui.greenguard|Xiaomi GreenGuard|MIUI GreenGuard service. Monitors app behavior and reports to Xiaomi. Another background telemetry channel.|Stops another telemetry channel. Reclaim background CPU.|Safe to remove. No user-facing functionality breaks."
  "com.google.android.feedback|Google Feedback|Google's crash/feedback reporter. Triggers on crashes and uploads detailed device state and logs to Google.|Stops automatic crash report telemetry to Google.|Safe to remove. Manual feedback via Settings still works."
  "com.android.adservices.api|Android AdServices API|Android 13 Privacy Sandbox ad framework. Background ad measurement and tracking infrastructure for the new Privacy Sandbox API.|Stops Google's new ad measurement framework. Privacy win.|Safe to remove. No apps currently depend on Privacy Sandbox ads. If an app needs it in the future, restore via restore.sh."
  "com.google.mainline.adservices|Mainline AdServices module|The ad services module delivered via Google Play system updates (Project Mainline). Handles ad measurement and privacy sandbox features.|Stops the Mainline ad services module. Privacy win.|Safe to remove. No user-facing functionality breaks."
  "com.google.android.configupdater|Google Config Updater|Silently updates Google configuration data in the background (carrier configs, Wi-Fi configs, etc.) without going through Play Store. Phones home for config updates.|Stops silent background config updates from Google. Reduces background network activity.|Safe to remove. Carrier and Wi-Fi configs are handled by the system directly. Apps still get their configs through normal channels."
)

BATCH2=(
  "com.miui.video|Mi Video|Xiaomi's default video player. Includes Xiaomi's video streaming service (mostly Chinese catalog), ads, and a custom video engine.|Replaced by VLC, MX Player, or any other video player.|Safe to remove. Video playback in other apps unaffected."
  "com.miui.mediaeditor|Mi Media Editor|Xiaomi's built-in media editor (photo/video editing). Basic editing tools with Xiaomi branding and tracking.|Replaced by any dedicated photo/video editor (Snapseed, Lightroom, CapCut, etc.).|Safe to remove. Camera app still takes photos. Third-party editors work fine."
  "com.miui.extraphoto|Mi Extra Photo|Extra photo features module (AI scene detection, photo enhancement, watermark, etc.). Adds Xiaomi-specific photo processing overlays.|Removes Xiaomi's extra photo processing features. Third-party camera apps unaffected.|Removing disables some Xiaomi camera features (AI scene detection, photo enhancement). Basic camera still works. Use GCam or third-party camera app for better results."
  "com.miui.vipservice|Xiaomi VIP Service|Xiaomi VIP/membership service. Pushes membership promotions, points, and rewards notifications. Mostly relevant in China.|Useless outside China. Removes a notification spam source.|Safe to remove. No functionality breaks."
)

BATCH3=(
  "com.miui.mishare.connectivity|Mi Share|Xiaomi's file sharing service (similar to AirDrop). Runs in background looking for nearby Xiaomi devices. Uses Bluetooth and Wi-Fi Direct.|Replaced by Quick Share, Nearby Share, or any other file sharing method.|Safe to remove. If you need Mi Share later, restore via restore.sh."
  "com.miui.touchassistant|TouchAssistant (Quick Ball)|A floating ball on the screen edge with shortcuts (screenshot, lock, recent apps, back). Gimmick feature that uses RAM and screen space.|Gimmick; uses RAM. Most people disable it within a day.|Safe to remove. All functions it offers are available elsewhere."
  "com.miui.hybrid|Hybrid (Quick Apps engine)|Xiaomi's Quick Apps / hybrid app engine. Runs lightweight mini-apps within MIUI. Also surfaces app recommendations. Background service.|Removes an app recommendation surface and background service.|Safe to remove. No functionality breaks."
  "com.miui.hybrid.accessory|Hybrid accessory|Companion module for the Hybrid Quick Apps engine. Provides accessory functionality for quick apps.|Same as Hybrid - removes part of the quick app engine.|Safe to remove. Works together with com.miui.hybrid removal."
  "com.miui.cleanmaster|Mi Cleaner|Xiaomi's storage cleaner / junk file scanner. Based on Cheetah Mobile's CleanMaster. Shows ads and upsells Xiaomi services. Runs in background.|Removes an ad surface and background scanner. Play Store has better cleaner apps.|Safe to remove. Main Security Center still works. Core security features unaffected."
  "com.miui.yellowpage|YellowPage|Xiaomi's business directory. Shows nearby businesses with paid placements. Mostly useless outside China. Pushes promotional notifications.|Useless in most regions. Removes a notification spam source.|Safe to remove. No contacts or dialer functionality breaks."
  "com.miui.personalassistant|MIUI Personal Assistant|The MIUI personal assistant / minus screen (leftmost home screen page on CN MIUI). Shows news, ads, recommendations, and widgets. Indexes app usage and sends to Xiaomi. Uses significant RAM.|Ad surface and telemetry channel. Big RAM user. Replaced by Google Discover or nothing.|Removing removes the leftmost minus screen page. Home screen still works. You can add widgets to other pages."
  "com.miui.miinput|Mi Keyboard|Xiaomi's default keyboard (Sogou-based on CN). Includes Xiaomi tracking and sends typing data to Xiaomi servers. You are using Gboard as default.|You already use Gboard. Removes a tracking surface and saves RAM.|Safe to remove. Gboard (com.google.android.inputmethod.latin) is your active keyboard and is NOT removed."
  "com.miui.carlink|Mi CarLink|Xiaomi's car connectivity service. Connects phone to compatible car infotainment systems. Runs in background looking for compatible cars.|Only useful if you have a compatible car. Otherwise wasted background activity.|Safe to remove. If you get a compatible car later, restore via restore.sh."
  "com.miui.vsimcore|Virtual SIM Core|Xiaomi's virtual SIM (eSIM) core service. CN-specific eSIM management. Runs in background.|CN-specific feature. If you don't use Xiaomi's virtual SIM, it's wasted background activity.|Safe to remove. Physical SIM and normal eSIM management through Settings still work."
  "com.miui.vpnsdkmanager|VPN SDK Manager|Xiaomi's VPN SDK manager. Provides VPN framework for Xiaomi apps. Background service.|Not needed for normal VPN usage. Third-party VPN apps work independently.|Safe to remove. Third-party VPN apps (WireGuard, OpenVPN, Tailscale, etc.) work fine without it."
  "com.miui.securityadd|Security add-on module|An add-on for Xiaomi Security Center that adds redundant 'optimization' features (deep clean, junk scan). Mostly upsells Xiaomi services and shows ads.|Redundant with the main Security Center. Removes an ad surface.|Safe to remove. Main Security Center (com.miui.securitycenter) still works. Core security features unaffected."
)

BATCH4=(
  "com.miui.translation.kingsoft|Kingsoft Translation|Xiaomi's translation service powered by Kingsoft (WPS). Provides in-system translation for text and content. CN-focused.|Rarely used outside China. Frees RAM and background activity.|Safe to remove. Google Translate or any third-party translation app works independently."
  "com.miui.translationservice|Translation Service|MIUI's translation framework service. Provides translation APIs to other MIUI apps. Runs in background.|Same as Kingsoft Translation - rarely used outside China.|Safe to remove. Works together with other translation package removals."
  "com.miui.translation.xmcloud|Xiaomi Cloud Translation|Xiaomi's cloud-based translation service. Sends text to Xiaomi cloud servers for translation. Privacy concern - text data goes to Xiaomi.|Privacy concern (text data to Xiaomi cloud). Rarely used outside China.|Safe to remove. Third-party translation apps work independently."
  "com.xiaomi.aiasst.service|Xiaomi AI Assistant Service|Xiaomi's AI assistant backend service. Powers the XiaoAI voice assistant (CN-only). Runs in background. Collects voice and usage data.|XiaoAI is CN-only and useless outside China. Stops voice data collection.|Safe to remove. Google Assistant (if kept) works independently."
  "com.xiaomi.aiasst.vision|Xiaomi AI Assistant Vision|Xiaomi's AI vision service. Provides visual recognition features for the AI assistant (scene recognition, text extraction, etc.). CN-focused.|CN-focused AI feature. Rarely used outside China.|Safe to remove. Google Lens (if installed) works independently."
  "com.xiaomi.aireco|Xiaomi AI Recommendation|Xiaomi's AI recommendation engine. Analyzes app usage and recommends content/apps. Sends usage data to Xiaomi. Background service.|Telemetry and recommendation engine. Privacy concern.|Safe to remove. No user-facing functionality breaks."
  "com.xiaomi.barrage|Xiaomi Barrage (bullet comments)|Danmaku-style floating bullet comments overlay for videos. A Chinese market feature where viewers' comments float across the video. Useless outside China.|Chinese-market feature, useless outside China.|Safe to remove. No video playback functionality breaks."
  "com.xiaomi.mirror|Xiaomi Mirror (screen cast)|Xiaomi's screen mirroring / casting service. Casts phone screen to Xiaomi TVs and compatible devices. Runs in background.|Replaced by Chromecast, Google Home, or other casting apps.|Safe to remove. If you cast to Xiaomi TVs, restore via restore.sh."
  "com.xiaomi.NetworkBoost|Xiaomi NetworkBoost|Xiaomi's network optimization service. Prioritizes network traffic for gaming and foreground apps. Runs in background.|Marginal benefit. Removing reduces background CPU usage.|Safe to remove. Network still works. You may notice slightly different traffic prioritization in games."
  "com.xiaomi.gamecenter.sdk.service|Game Center SDK Service|Xiaomi Game Center SDK service. Provides game center integration, achievements, and game recommendations. Background service.|If you don't use Xiaomi Game Center, it's wasted background activity.|Safe to remove. Games still launch and run normally."
  "com.xiaomi.macro|Xiaomi Macro|Xiaomi's macro mode service for the camera. Enables close-up macro photography with the ultrawide lens.|Removing disables the camera's macro mode. Normal camera still works.|If you use macro photography, do NOT remove this. Otherwise safe to remove."
  "com.xiaomi.cameratools|Xiaomi Camera Tools|Xiaomi's camera tools module. Provides additional camera utilities and features (document scanner, translation in camera, etc.).|Removes some extra camera utilities. Basic camera unaffected.|Some camera extra features (document scan, text extraction in camera) may be unavailable. Basic photo/video still works."
  "com.xiaomi.digitalkey|Xiaomi Digital Key|Xiaomi's digital key service for car keys and smart home locks. Runs in background looking for compatible devices.|Only useful if you have a compatible car or smart lock. Otherwise wasted background activity.|Safe to remove. If you get a compatible device later, restore via restore.sh."
  "com.xiaomi.metoknlp|Xiaomi MetokNLP|Xiaomi's location/NLP (Natural Language Processing) service. Provides location-based services for Xiaomi apps. CN-focused. Sends location data to Xiaomi.|CN-focused location service. Privacy concern (location data to Xiaomi). Google's fused location works independently.|Removing may slightly reduce location accuracy for Xiaomi apps. Google Maps and other third-party apps use Google's fused location provider, which is NOT removed."
)

BATCH5=(
  "com.google.android.googlequicksearchbox|Google App (Quick Search Box)|Google's main app. Powers the Google Discover feed (swipe left on home screen), voice search, hotword detection, and the Google search widget. Sends search and usage data to Google. Uses significant RAM when active.|If you don't use Google Discover or voice search, it's wasted RAM and background activity. Frees significant RAM.|Removing disables Google Discover feed, voice search via hotword, and the Google search widget. Google Assistant (separate package) may also lose functionality. You can still search via Chrome. If you use voice commands, do NOT remove this."
  "com.google.android.apps.googleassistant|Google Assistant|Google Assistant standalone app. Provides voice assistant functionality, routines, and visual assistant UI. Runs in background.|If you don't use Google Assistant, it's wasted background activity.|Removing disables Google Assistant. If you use voice commands, do NOT remove this. You can reinstall from Play Store if needed."
  "com.google.android.marvin.talkback|TalkBack (Accessibility)|Google's screen reader for visually impaired users. Speaks on-screen content aloud. Runs as an accessibility service.|If you don't use a screen reader, it's wasted background activity.|Safe to remove. If you or someone else needs accessibility features, restore via restore.sh or install from Play Store."
  "com.google.android.projection.gearhead|Android Auto|Google's Android Auto app. Projects phone interface to compatible car infotainment systems. Runs in background looking for compatible cars.|Only useful if you have a compatible car with Android Auto. Otherwise wasted background activity.|Safe to remove. If you get a compatible car later, install Android Auto from Play Store."
  "com.google.android.printservice.recommendation|Print Service Recommender|Recommends print service plugins based on your printer. Runs in background.|Rarely used. Most people install their printer's app directly.|Safe to remove. Printing still works if you have a print service installed."
  "com.google.android.onetimeinitializer|One-time Initializer|Runs once during initial device setup to initialize Google services. Dormant after setup.|Only runs during initial setup. Removing after setup is safe.|Safe to remove after initial setup. If you factory reset, restore this first via restore.sh."
  "com.google.android.partnersetup|Partner Setup|Configures Google partner settings during initial device setup. Dormant after setup.|Same as one-time initializer - only needed during setup.|Safe to remove after initial setup. Restore before a factory reset."
  "com.google.android.setupwizard|Setup Wizard|The initial device setup wizard (Google account sign-in, etc.). Dormant after setup.|Only needed during initial setup. Removing after setup is safe.|Safe to remove after initial setup. If you factory reset, restore this first via restore.sh."
  "com.google.android.apps.turbo|Google Turbo (Smart Battery)|Google's Smart Battery / Device Health Services. Provides battery usage graphs, screen time, and battery predictions. Runs in background.|If you don't use Google's battery stats, it's wasted background activity. MIUI has its own battery stats.|Removing may disable Google's battery usage screen in Settings. MIUI's own battery stats (in Security Center) still work."
  "com.google.android.apps.wellbeing|Digital Wellbeing|Google's screen time tracker. Shows app usage time, sets app timers, wind-down mode, focus mode. Uses RAM when running.|Screen time tracker not used. Frees RAM.|Safe to remove. If you want it back, install from Play Store."
  "com.google.android.as|Android System Intelligence|Google's on-device AI platform. Powers Now Playing (music recognition), Smart Select, Live Caption, Notification Summary, Enhanced Notifications, and other AI features. Uses RAM and CPU for on-device ML.|Aggressive removal. Frees RAM and CPU from on-device ML workloads.|Removing disables: Now Playing, Smart Select, Live Caption, Notification Summary, and other AI-powered features. Basic phone functionality is unaffected. If you use any of these AI features, do NOT remove this. You can reinstall from Play Store."
)

# ---------- Parse args ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) INTERACTIVE=0 ;;
    --list|-l) LIST_ONLY=1 ;;
    --batch) BATCH_FILTER="$2"; shift ;;
    --batch=*) BATCH_FILTER="${1#--batch=}" ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---------- Main ----------
echo "${C_CYAN}${C_BOLD}POCO X3 Pro Debloat${C_RESET}"
echo "Log file: $LOG_FILE"
echo ""

if [ "$LIST_ONLY" = "0" ]; then
  check_device
  mkdir -p "$BACKUP_DIR"
  if [ ! -f "$LOG_FILE" ]; then
    cat > "$LOG_FILE" <<EOF
# Packages removed from POCO X3 Pro via debloat.sh
# Restore with: bash ${SCRIPT_DIR}/restore.sh
EOF
  fi
fi

if [ "$INTERACTIVE" = "1" ] && [ "$LIST_ONLY" = "0" ]; then
  echo "${C_DIM}This script will walk you through each package one by one."
  echo "For each package, you'll see:"
  echo "  - What it is"
  echo "  - Why it's being removed"
  echo "  - Current RAM usage (if running)"
  echo "Then you choose: 1 (remove), 2 (keep), or 3 (skip rest of batch)."
  echo ""
  echo "Everything is reversible - run restore.sh to undo any removal.${C_RESET}"
  echo ""
fi

run_one() {
  local n="$1" name="$2"; shift 2
  if [ -z "$BATCH_FILTER" ] || [ "$BATCH_FILTER" = "$n" ]; then
    run_batch "$n" "$name" "$@"
  fi
}

run_one 1 "Telemetry & Ads"                    "${BATCH1[@]}"
run_one 2 "MIUI duplicate/media apps"          "${BATCH2[@]}"
run_one 3 "MIUI system utilities & junk"       "${BATCH3[@]}"
run_one 4 "MIUI AI, translation & gaming"      "${BATCH4[@]}"
run_one 5 "Google bloat"                       "${BATCH5[@]}"

if [ "$LIST_ONLY" = "1" ]; then
  echo "List-only mode - nothing was changed."
else
  echo "${C_GREEN}Done.${C_RESET} Removed packages are logged in: $LOG_FILE"
  echo "To undo everything:  bash ${SCRIPT_DIR}/restore.sh"
  echo "To undo one package: bash ${SCRIPT_DIR}/restore.sh <pkg>"
fi
