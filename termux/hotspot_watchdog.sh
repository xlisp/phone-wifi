#!/data/data/com.termux/files/usr/bin/bash
# Hotspot watchdog for Termux.
# - keeps a wakelock so the CPU does not sleep
# - logs hotspot state, internet reachability, battery temperature, cell signal
# - restarts the hotspot (root or adb) or notifies you when it drops
#
# Usage:  SSID=MyAP PASS=12345678 BAND=5 bash hotspot_watchdog.sh
# Log:    ~/hotspot.log   (look here first to see WHICH side is dropping)
set -u

SSID=${SSID:-Mi12SU}
PASS=${PASS:-changeme123}
BAND=${BAND:-5}              # 2 = 2.4GHz (range, walls) / 5 = 5GHz (speed, short range)
INTERVAL=${INTERVAL:-15}     # seconds between checks
PING_HOST=${PING_HOST:-223.5.5.5}
LOG=${LOG:-$HOME/hotspot.log}
HOT_TEMP=${HOT_TEMP:-42}     # battery °C above which we warn (MIUI throttles ~43-45)

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

if su -c true >/dev/null 2>&1; then
  RUN() { su -c "$*"; }; MODE=root
elif adb devices 2>/dev/null | grep -q 'device$'; then
  RUN() { adb shell "$*"; }; MODE=adb
else
  RUN() { return 1; }; MODE=none
fi

notify() {
  command -v termux-notification >/dev/null &&
    termux-notification --id hotspot --title "Hotspot" --content "$1" --priority high
}

# Softap interface on Xiaomi is usually wlan1/ap0/swlan0 and gets a 192.168.x.1 or 10.x.x.1 address.
ap_iface() {
  ip -o -4 addr show 2>/dev/null | awk '$2 ~ /^(ap[0-9]|wlan[1-9]|swlan[0-9]|softap[0-9])$/ {print $2; exit}'
}

clients() {
  [ "$MODE" = none ] && { echo "?"; return; }
  RUN "ip neigh show dev $1 2>/dev/null" | grep -c -E 'REACHABLE|STALE|DELAY'
}

batt_temp() {
  if command -v termux-battery-status >/dev/null; then
    termux-battery-status 2>/dev/null | awk -F': ' '/temperature/ {gsub(/,/,"",$2); printf "%.0f", $2}'
  elif [ "$MODE" != none ]; then
    RUN dumpsys battery | awk '/temperature/ {printf "%.0f", $2/10}'
  fi
}

signal() {
  [ "$MODE" = none ] && return
  # e.g. "rsrp=-98 rsrq=-11" for LTE/NR; smaller magnitude = better
  RUN dumpsys telephony.registry 2>/dev/null |
    grep -m1 -o 'mSignalStrength=.*' | grep -o -E '(ssRsrp|rsrp|rsrq|ssSinr|rssnr)=-?[0-9]+' | head -4 | tr '\n' ' '
}

start_ap() {
  case $MODE in
    root|adb)
      # Android 12+ syntax; band flag: -b 2|5|any
      RUN cmd wifi start-softap "$SSID" wpa2 "$PASS" -b "$BAND" && return 0 ;;
  esac
  # Non-root fallback: open the hotspot page so you can tap it on.
  am start -a android.settings.TETHER_SETTINGS >/dev/null 2>&1 \
    || am start -n com.android.settings/.TetherSettings >/dev/null 2>&1
  notify "Hotspot is OFF - tap to re-enable"
  return 1
}

termux-wake-lock 2>/dev/null
trap 'termux-wake-unlock 2>/dev/null; exit' INT TERM
log "watchdog start mode=$MODE ssid=$SSID band=$BAND"

fails=0
while :; do
  ifc=$(ap_iface)
  temp=$(batt_temp)
  if ping -c 2 -W 3 "$PING_HOST" >/dev/null 2>&1; then net=OK; fails=0; else net=DOWN; fails=$((fails+1)); fi

  if [ -z "$ifc" ]; then
    log "AP=OFF net=$net temp=${temp}C -> restarting hotspot"
    start_ap && log "AP restart issued"
    sleep 10; continue
  fi

  log "AP=$ifc clients=$(clients "$ifc") net=$net temp=${temp}C $(signal)"

  # Cellular side is down for ~1 min: toggle mobile data to force re-attach.
  if [ "$fails" -ge 4 ] && [ "$MODE" != none ]; then
    log "uplink down ${fails}x -> toggling mobile data"
    RUN svc data disable; sleep 3; RUN svc data enable
    fails=0
  fi

  if [ -n "$temp" ] && [ "$temp" -ge "$HOT_TEMP" ]; then
    notify "Phone ${temp}C - cool it down or speed will throttle / AP may drop"
  fi

  sleep "$INTERVAL"
done
