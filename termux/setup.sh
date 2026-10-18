#!/data/data/com.termux/files/usr/bin/bash
# One-time setup: install tools and apply hotspot-friendly system settings.
# Run inside Termux on the phone:  bash setup.sh
set -u

pkg install -y android-tools termux-api iputils >/dev/null 2>&1 || pkg install -y android-tools termux-api

# Pick a privileged runner: root (Magisk) > adb over localhost (Wireless debugging) > none.
if su -c true >/dev/null 2>&1; then
  RUN() { su -c "$*"; }
  echo "[setup] using root"
elif adb devices 2>/dev/null | grep -q 'device$'; then
  RUN() { adb shell "$*"; }
  echo "[setup] using adb"
else
  cat <<'EOF'
[setup] No root and no adb connection. To use adb from Termux (no root needed):
  1. Developer options -> Wireless debugging -> ON
  2. Tap "Pair device with pairing code" (use split screen with Termux)
       adb pair localhost:<PAIR_PORT> <CODE>
  3. Then connect using the port shown on the Wireless debugging page:
       adb connect localhost:<PORT>
  4. Re-run: bash setup.sh
Note: Wireless debugging needs Wi-Fi to be ON (it can stay on alongside the hotspot).
EOF
  exit 1
fi

# Keep mobile data radio up even when Wi-Fi is active.
RUN settings put global mobile_data_always_on 1
# Disable tethering hardware offload: on many Qualcomm/MIUI builds this fixes
# clients that stay "connected" but lose internet. Revert with 0 if throughput drops.
RUN settings put global tether_offload_disabled 1
# Exempt Termux and the tethering stack from Doze / battery optimisation.
for p in com.termux com.termux.api com.android.networkstack.tethering com.android.settings; do
  RUN dumpsys deviceidle whitelist +$p >/dev/null 2>&1
done
RUN cmd appops set com.termux RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1

echo "[setup] done. Current values:"
RUN settings get global mobile_data_always_on
RUN settings get global tether_offload_disabled
