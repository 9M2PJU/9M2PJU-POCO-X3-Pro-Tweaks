#!/usr/bin/env bash
# ============================================================
# POCO X3 Pro (vayu) - Restore script
# ============================================================
# Restores packages removed by debloat.sh.
# Method: pm install-existing --user 0  (re-registers the app from the
# untouched /system APK - no internet needed, instant).
#
# Usage:
#   bash restore.sh                  # interactive: explain + prompt per package
#   bash restore.sh --yes            # non-interactive, restore everything
#   bash restore.sh com.miui.analytics           # restore one package
#   bash restore.sh com.miui.analytics com.xiaomi.joyose   # restore several
#   bash restore.sh --batch 2        # restore a specific batch (by number)
#   bash restore.sh --list           # show what would be restored, do nothing
# ============================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backup"
LOG_FILE="${BACKUP_DIR}/removed_packages.txt"
INTERACTIVE=1
LIST_ONLY=0
BATCH_FILTER=""
EXPLICIT_PKGS=()

# Colors
if [ -t 1 ]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

# ---------- Pre-flight ----------
if ! command -v adb >/dev/null 2>&1; then
  echo "${C_RED}ERROR: adb not found in PATH${C_RESET}" >&2
  exit 1
fi
if ! adb devices 2>/dev/null </dev/null | grep -q '\bdevice$'; then
  echo "${C_RED}ERROR: no adb device connected.${C_RESET}" >&2
  echo "Run 'adb devices' to check." >&2
  exit 1
fi

# ---------- Package metadata (mirrors debloat.sh) ----------
# Format: "package|what|details|why_was_removed|caveats"
PKG_META=(
  "com.miui.analytics|Xiaomi Analytics|Collects app usage patterns, feature usage, crash stats, device telemetry. Uploads to Xiaomi.|Was removed: usage pattern reporting to Xiaomi.|Restoring re-enables telemetry collection. No user-facing feature added."
  "com.miui.systemAdSolution|Xiaomi Ad SDK (MSA equivalent)|Xiaomi's system ad solution. Injects ads into Notification shade, Settings, Security Center. Persistent background service.|Was removed: pushes ads across the OS and collects ad-targeting data.|Restoring re-enables ads in Notification shade, Settings, and other Xiaomi apps."
  "com.miui.misightservice|Xiaomi MiSight (insights/telemetry)|Xiaomi's insights and telemetry service. Collects device health, feature usage, system metrics. Phones home.|Was removed: telemetry channel to Xiaomi.|Restoring re-enables another telemetry channel to Xiaomi."
  "com.xiaomi.joyose|Xiaomi Joyose (telemetry + Game Turbo)|Background service: usage analytics, device health reporting, Game Turbo backend. Phones home with usage patterns and performance metrics.|Was removed: Xiaomi usage analytics and telemetry.|Restoring re-enables Game Turbo advanced features (per-game GPU/CPU tuning, brightness lock, calls blocking during games)."
  "com.miui.greenguard|Xiaomi GreenGuard|MIUI GreenGuard service. Monitors app behavior and reports to Xiaomi. Background telemetry channel.|Was removed: another telemetry channel.|Restoring re-enables background telemetry to Xiaomi."
  "com.google.android.feedback|Google Feedback|Google's crash/feedback reporter. Uploads device state and logs to Google on crashes.|Was removed: automatic crash report telemetry to Google.|Restoring re-enables automatic crash report uploads."
  "com.android.adservices.api|Android AdServices API|Android 13 Privacy Sandbox ad framework. Background ad measurement and tracking infrastructure.|Was removed: Google's new ad measurement framework.|Restoring re-enables the Privacy Sandbox ad framework."
  "com.google.mainline.adservices|Mainline AdServices module|The ad services module delivered via Google Play system updates (Project Mainline).|Was removed: Mainline ad services module.|Restoring re-enables the Mainline ad services module."
  "com.google.android.configupdater|Google Config Updater|Silently updates Google configuration data in the background without going through Play Store.|Was removed: silent background config updates from Google.|Restoring re-enables silent background config updates."
  "com.miui.video|Mi Video|Xiaomi's default video player. Includes Xiaomi's video streaming service (mostly Chinese catalog), ads.|Was removed: replaced by VLC/MX Player/other.|Restoring brings back Mi Video with ads."
  "com.miui.mediaeditor|Mi Media Editor|Xiaomi's built-in media editor (photo/video editing).|Was removed: replaced by dedicated editors.|Restoring brings back the Mi media editor."
  "com.miui.extraphoto|Mi Extra Photo|Extra photo features module (AI scene detection, photo enhancement, watermark).|Was removed: Xiaomi-specific photo processing.|Restoring re-enables AI scene detection and photo enhancement in the camera app."
  "com.miui.vipservice|Xiaomi VIP Service|Xiaomi VIP/membership service. Pushes membership promotions and rewards notifications.|Was removed: useless outside China; notification spam.|Restoring may re-enable promotional notifications."
  "com.miui.mishare.connectivity|Mi Share|Xiaomi's file sharing service (similar to AirDrop). Runs in background.|Was removed: replaced by Quick Share/Nearby Share.|Restoring re-enables Mi Share background service."
  "com.miui.touchassistant|TouchAssistant (Quick Ball)|Floating ball on screen edge with shortcuts. Gimmick; uses RAM.|Was removed: gimmick; uses RAM.|Restoring brings back the floating ball. You can disable it in Settings."
  "com.miui.hybrid|Hybrid (Quick Apps engine)|Xiaomi's Quick Apps / hybrid app engine. Surfaces app recommendations. Background service.|Was removed: app recommendation surface and background service.|Restoring re-enables the quick app engine and recommendations."
  "com.miui.hybrid.accessory|Hybrid accessory|Companion module for the Hybrid Quick Apps engine.|Was removed: part of the quick app engine.|Restoring completes the quick app engine."
  "com.miui.cleanmaster|Mi Cleaner|Xiaomi's storage cleaner / junk file scanner. Based on Cheetah Mobile's CleanMaster. Shows ads.|Was removed: ad surface and background scanner.|Restoring brings back Mi Cleaner with ads."
  "com.miui.yellowpage|YellowPage|Xiaomi business directory with paid placements. Mostly useless outside China.|Was removed: useless in most regions; notification spam.|Restoring may re-enable promotional notifications."
  "com.miui.personalassistant|MIUI Personal Assistant|The MIUI personal assistant / minus screen. Shows news, ads, recommendations. Indexes app usage and sends to Xiaomi.|Was removed: ad surface and telemetry; big RAM user.|Restoring brings back the minus screen with ads and usage indexing."
  "com.miui.miinput|Mi Keyboard|Xiaomi's default keyboard (Sogou-based on CN). Sends typing data to Xiaomi.|Was removed: you use Gboard; tracking surface.|Restoring brings back Mi Keyboard. Gboard remains your default unless you change it."
  "com.miui.carlink|Mi CarLink|Xiaomi's car connectivity service. Runs in background.|Was removed: only useful with compatible cars.|Restoring re-enables car connectivity background service."
  "com.miui.vsimcore|Virtual SIM Core|Xiaomi's virtual SIM (eSIM) core service. CN-specific.|Was removed: CN-specific feature not used.|Restoring re-enables the virtual SIM service."
  "com.miui.vpnsdkmanager|VPN SDK Manager|Xiaomi's VPN SDK manager. Provides VPN framework for Xiaomi apps.|Was removed: not needed for normal VPN usage.|Restoring re-enables the Xiaomi VPN SDK. Third-party VPN apps work without it."
  "com.miui.securityadd|Security add-on module|Add-on for Security Center with redundant 'optimization' features. Shows ads.|Was removed: redundant; ad surface.|Restoring brings back the add-on with ads. Main Security Center works without it."
  "com.miui.translation.kingsoft|Kingsoft Translation|Xiaomi's translation service powered by Kingsoft. CN-focused.|Was removed: rarely used outside China.|Restoring re-enables Kingsoft-powered translation in MIUI."
  "com.miui.translationservice|Translation Service|MIUI's translation framework service. Background service.|Was removed: rarely used outside China.|Restoring re-enables the translation framework."
  "com.miui.translation.xmcloud|Xiaomi Cloud Translation|Xiaomi's cloud-based translation. Sends text to Xiaomi cloud servers.|Was removed: privacy concern (text to Xiaomi cloud).|Restoring re-enables cloud translation with text data going to Xiaomi."
  "com.xiaomi.aiasst.service|Xiaomi AI Assistant Service|Xiaomi's AI assistant backend (XiaoAI). CN-only. Collects voice and usage data.|Was removed: CN-only; voice data collection.|Restoring re-enables XiaoAI assistant. Useless outside China."
  "com.xiaomi.aiasst.vision|Xiaomi AI Assistant Vision|Xiaomi's AI vision service (scene recognition, text extraction). CN-focused.|Was removed: CN-focused AI feature.|Restoring re-enables AI vision features."
  "com.xiaomi.aireco|Xiaomi AI Recommendation|Xiaomi's AI recommendation engine. Analyzes usage and recommends content. Sends data to Xiaomi.|Was removed: telemetry and recommendation engine.|Restoring re-enables the recommendation engine and usage data collection."
  "com.xiaomi.barrage|Xiaomi Barrage (bullet comments)|Danmaku-style floating bullet comments for videos. Chinese market feature.|Was removed: Chinese-market feature, useless outside China.|Restoring brings back bullet comments. Only useful on Chinese video platforms."
  "com.xiaomi.mirror|Xiaomi Mirror (screen cast)|Xiaomi's screen mirroring / casting service. Runs in background.|Was removed: replaced by Chromecast/Google Home.|Restoring re-enables Xiaomi screen casting."
  "com.xiaomi.NetworkBoost|Xiaomi NetworkBoost|Xiaomi's network optimization service. Prioritizes traffic for gaming/foreground apps.|Was removed: marginal benefit; background CPU usage.|Restoring re-enables network traffic prioritization."
  "com.xiaomi.gamecenter.sdk.service|Game Center SDK Service|Xiaomi Game Center SDK. Game center integration, achievements, recommendations.|Was removed: not using Xiaomi Game Center.|Restoring re-enables Game Center integration."
  "com.xiaomi.macro|Xiaomi Macro|Xiaomi's macro mode service for the camera. Enables close-up macro photography.|Was removed: macro mode not used.|Restoring re-enables camera macro mode."
  "com.xiaomi.cameratools|Xiaomi Camera Tools|Xiaomi's camera tools module (document scanner, translation in camera, etc.).|Was removed: extra camera utilities not used.|Restoring re-enables camera extra features (document scan, text extraction)."
  "com.xiaomi.digitalkey|Xiaomi Digital Key|Xiaomi's digital key service for car keys and smart home locks.|Was removed: no compatible devices.|Restoring re-enables digital key background service."
  "com.xiaomi.metoknlp|Xiaomi MetokNLP|Xiaomi's location/NLP service. CN-focused. Sends location data to Xiaomi.|Was removed: CN-focused; location data to Xiaomi.|Restoring re-enables Xiaomi location services. May slightly improve location accuracy for Xiaomi apps."
  "com.google.android.googlequicksearchbox|Google App (Quick Search Box)|Google's main app. Powers Discover feed, voice search, hotword detection, search widget.|Was removed: not using Discover or voice search; RAM savings.|Restoring re-enables Google Discover, voice search, and the search widget."
  "com.google.android.apps.googleassistant|Google Assistant|Google Assistant standalone app. Voice assistant, routines, visual assistant UI.|Was removed: not using Google Assistant.|Restoring re-enables Google Assistant."
  "com.google.android.marvin.talkback|TalkBack (Accessibility)|Google's screen reader for visually impaired users.|Was removed: not using screen reader.|Restoring re-enables the screen reader. Install from Play Store if needed."
  "com.google.android.projection.gearhead|Android Auto|Google's Android Auto. Projects phone to car infotainment.|Was removed: no compatible car.|Restoring re-enables Android Auto. Install from Play Store if needed."
  "com.google.android.printservice.recommendation|Print Service Recommender|Recommends print service plugins based on your printer.|Was removed: rarely used.|Restoring re-enables print service recommendations."
  "com.google.android.onetimeinitializer|One-time Initializer|Runs once during initial setup to initialize Google services.|Was removed: only needed during setup.|Restoring re-enables the setup initializer. Restore before a factory reset."
  "com.google.android.partnersetup|Partner Setup|Configures Google partner settings during initial setup.|Was removed: only needed during setup.|Restoring re-enables partner setup. Restore before a factory reset."
  "com.google.android.setupwizard|Setup Wizard|The initial device setup wizard (Google account sign-in, etc.).|Was removed: only needed during setup.|Restoring re-enables the setup wizard. Restore before a factory reset."
  "com.google.android.apps.turbo|Google Turbo (Smart Battery)|Google's Smart Battery / Device Health Services. Battery usage graphs, screen time, predictions.|Was removed: not using Google battery stats; MIUI has its own.|Restoring re-enables Google's battery usage screen in Settings."
  "com.google.android.apps.wellbeing|Digital Wellbeing|Google's screen time tracker. App usage time, timers, wind-down, focus mode.|Was removed: screen time tracker not used.|Restoring brings back Digital Wellbeing. Install from Play Store if needed."
  "com.google.android.as|Android System Intelligence|Google's on-device AI platform. Powers Now Playing, Smart Select, Live Caption, Notification Summary, etc.|Was removed: aggressive removal; frees RAM and CPU from on-device ML.|Restoring re-enables Now Playing, Smart Select, Live Caption, and other AI features. Install from Play Store if needed."
)

# ---------- Look up metadata for a package ----------
lookup_meta() {
  local pkg="$1"
  META_WHAT=""
  META_DETAILS=""
  META_WHY=""
  META_CAVEATS=""
  for entry in "${PKG_META[@]}"; do
    local p what details why caveats
    IFS='|' read -r p what details why caveats <<< "$entry"
    if [ "$p" = "$pkg" ]; then
      META_WHAT="$what"
      META_DETAILS="$details"
      META_WHY="$why"
      META_CAVEATS="$caveats"
      return 0
    fi
  done
}

# ---------- Check if a package is currently installed ----------
is_installed() {
  local pkg="$1"
  adb shell pm list packages --user 0 2>/dev/null </dev/null | grep -q "^package:${pkg}$"
}

# ---------- Restore one package ----------
# Returns: 0 = restored, 1 = failed, 2 = skipped (already installed)
restore_one() {
  local pkg="$1"
  pkg="${pkg#package:}"
  [ -z "$pkg" ] && return 2
  case "$pkg" in '#'*) return 2 ;; esac

  if is_installed "$pkg"; then
    echo "  ${C_YELLOW}SKIP${C_RESET}  $pkg (already installed for user 0)"
    return 2
  fi

  local out
  out=$(adb shell pm install-existing --user 0 "$pkg" 2>&1 </dev/null)
  if echo "$out" | grep -q 'Success'; then
    echo "  ${C_GREEN}OK${C_RESET}    $pkg"
    return 0
  else
    if adb shell pm enable --user 0 "$pkg" >/dev/null 2>&1 </dev/null; then
      echo "  ${C_GREEN}OK${C_RESET}    $pkg (was disabled, re-enabled)"
      return 0
    else
      echo "  ${C_RED}FAIL${C_RESET}  $pkg -> $out"
      return 1
    fi
  fi
}

# ---------- Display a package card ----------
show_pkg_card() {
  local pkg="$1"
  lookup_meta "$pkg"
  local status
  if is_installed "$pkg"; then
    CARD_INSTALLED=1
    status="${C_GREEN}currently installed${C_RESET}"
  else
    CARD_INSTALLED=0
    status="${C_YELLOW}currently removed${C_RESET}"
  fi
  echo ""
  echo "  ${C_BOLD}Package:${C_RESET}  $pkg"
  if [ -n "$META_WHAT" ]; then
    echo "  ${C_BOLD}What:${C_RESET}     $META_WHAT"
  else
    echo "  ${C_BOLD}What:${C_RESET}     (no description available)"
  fi
  if [ -n "$META_DETAILS" ]; then
    echo "  ${C_BOLD}Details:${C_RESET} $META_DETAILS"
  fi
  if [ -n "$META_WHY" ]; then
    echo "  ${C_BOLD}History:${C_RESET}  $META_WHY"
  fi
  if [ -n "$META_CAVEATS" ]; then
    echo "  ${C_BOLD}Restoring:${C_RESET} $META_CAVEATS"
  fi
  echo "  ${C_BOLD}Status:${C_RESET}    $status"
}

# ---------- Parse args ----------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y) INTERACTIVE=0 ;;
    --list|-l) LIST_ONLY=1 ;;
    --batch) BATCH_FILTER="$2"; shift ;;
    --batch=*) BATCH_FILTER="${1#--batch=}" ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0 ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) EXPLICIT_PKGS+=("$1") ;;
  esac
  shift
done

# ---------- Collect target packages ----------
TARGETS=()
if [ "${#EXPLICIT_PKGS[@]}" -gt 0 ]; then
  TARGETS=("${EXPLICIT_PKGS[@]}")
elif [ -n "$BATCH_FILTER" ]; then
  if [ ! -f "$LOG_FILE" ]; then
    echo "${C_RED}ERROR: $LOG_FILE not found.${C_RESET}" >&2
    exit 1
  fi
  mapfile -t TARGETS < <(awk -v b="$BATCH_FILTER" '
    /^# .*Batch [0-9]+/ {
      n = $0
      sub(/^.*Batch /, "", n)
      sub(/[^0-9].*$/, "", n)
      in_block = (n == b)
      next
    }
    /^#/  { next }
    /^$/  { next }
    in_block { print }
  ' "$LOG_FILE")
  if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "${C_RED}No packages found for batch $BATCH_FILTER in $LOG_FILE${C_RESET}" >&2
    exit 1
  fi
else
  if [ ! -f "$LOG_FILE" ]; then
    echo "${C_RED}ERROR: $LOG_FILE not found - nothing to restore.${C_RESET}" >&2
    exit 1
  fi
  mapfile -t TARGETS < <(grep -vE '^#|^$' "$LOG_FILE")
fi

# ---------- Run ----------
echo "${C_CYAN}${C_BOLD}POCO X3 Pro Restore${C_RESET}"
echo "Device: $(adb shell getprop ro.product.model </dev/null) ($(adb shell getprop ro.product.name </dev/null))"
echo "Packages to restore: ${#TARGETS[@]}"
echo ""

if [ "$LIST_ONLY" = "1" ]; then
  for p in "${TARGETS[@]}"; do
    lookup_meta "$p"
    if [ -n "$META_WHAT" ]; then
      echo "  would restore: $p  ${C_DIM}($META_WHAT)${C_RESET}"
    else
      echo "  would restore: $p"
    fi
  done
  echo ""
  echo "List-only mode - nothing was changed."
  exit 0
fi

if [ "$INTERACTIVE" = "1" ]; then
  echo "${C_DIM}This script will walk you through each package one by one."
  echo "For each package, you'll see what it is, why it was removed, and"
  echo "its current status (installed or removed)."
  echo "Then you choose: 1 (restore), 2 (keep removed), or 3 (skip rest).${C_RESET}"
  echo ""
fi

ok=0; fail=0; skip=0; kept=0
for p in "${TARGETS[@]}"; do
  case "$p" in '#'*|'') continue ;; esac

  if [ "$INTERACTIVE" = "1" ]; then
    show_pkg_card "$p"
    opt1_label="Restore"
    if [ "${CARD_INSTALLED:-0}" = "1" ]; then
      opt1_label="Restore (already installed - will skip)"
    fi
    echo ""
    echo "  ${C_BOLD}1)${C_RESET} ${opt1_label}"
    echo "  ${C_BOLD}2)${C_RESET} Keep removed"
    echo "  ${C_BOLD}3)${C_RESET} Skip rest of the restore list"
    while true; do
      printf "  ${C_BOLD}Choose [1-3] (default 2):${C_RESET} "
      read -r ans
      case "$ans" in
        1|restore|Restore|RESTORE|y|Y|yes|YES)
          restore_one "$p"
          rc=$?
          case "$rc" in
            0) ok=$((ok+1)) ;;
            1) fail=$((fail+1)) ;;
            2) skip=$((skip+1)) ;;
          esac
          break
          ;;
        3|skip|Skip|SKIP|s|S)
          echo "  ${C_DIM}Skipping rest of the restore list.${C_RESET}"
          break 2
          ;;
        2|keep|Keep|KEEP|n|N|no|NO|"")
          echo "  ${C_DIM}Kept removed: $p${C_RESET}"
          kept=$((kept+1))
          break
          ;;
        *)
          echo "  ${C_DIM}Please choose 1 (restore), 2 (keep removed), or 3 (skip rest).${C_RESET}"
          ;;
      esac
    done
  else
    restore_one "$p"
    rc=$?
    case "$rc" in
      0) ok=$((ok+1)) ;;
      1) fail=$((fail+1)) ;;
      2) skip=$((skip+1)) ;;
    esac
  fi
done

echo ""
echo "${C_GREEN}Done.${C_RESET} Restored=$ok  Skipped=$skip  Kept=$kept  Failed=$fail"
if [ "$kept" -gt 0 ]; then
  echo "${C_DIM}Kept=$kept packages were not restored (you chose to skip them).${C_RESET}"
fi
[ "$fail" -gt 0 ] && echo "${C_YELLOW}Some packages failed - they may have been removed by an OTA update. A factory reset will restore everything.${C_RESET}"
