#!/bin/bash
# Runs a command next to a headless GNOME Shell on a private D-Bus with throwaway XDG
# directories. The built extension (build/) and the test probe are installed there only.
#   tools/sandbox.sh <command> [args...]
# The command sees: HR_SANDBOX, HR_EXT_DIR, HR_SHELL_PID, HR_LOG
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
HELPER=hot-reload@thesalaty.github.io
export HR_SANDBOX=${HR_SANDBOX:-${TMPDIR:-/tmp}/hr-sandbox}

if [ -z "${HR_PRIVATE_BUS:-}" ]; then
  rm -rf "$HR_SANDBOX"
  mkdir -p "$HR_SANDBOX"/{home,config,data/gnome-shell/extensions,cache,state,work}
  # Own runtime dir, so the real session's Wayland socket and PipeWire stay out of reach.
  # Short path: socket paths are limited to 108 bytes.
  export HR_RT=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/hr-rt.XXXXXX")
  chmod 700 "$HR_RT"
  export HOME="$HR_SANDBOX/home"
  export XDG_CONFIG_HOME="$HR_SANDBOX/config"
  export XDG_DATA_HOME="$HR_SANDBOX/data"
  export XDG_CACHE_HOME="$HR_SANDBOX/cache"
  export XDG_STATE_HOME="$HR_SANDBOX/state"
  export XDG_RUNTIME_DIR="$HR_RT"
  export GIO_USE_VFS=local
  # dconf writes would otherwise reach the real session.
  export GSETTINGS_BACKEND=keyfile
  unset WAYLAND_DISPLAY DISPLAY XAUTHORITY GNOME_KEYRING_CONTROL SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS
  export GTK_A11Y=none
  export HR_EXT_DIR="$XDG_DATA_HOME/gnome-shell/extensions"
  # The environment has to be in place BEFORE the private bus starts: services the bus
  # activates (the prefs process, dconf-service, portals ...) inherit the bus daemon's
  # environment. With the real one they write to the real dconf and open windows on the
  # real desktop.
  HR_PRIVATE_BUS=1 exec dbus-run-session -- "$0" "$@"
fi

export HR_LOG="$HR_SANDBOX/shell.log"

mkdir "$HR_EXT_DIR/$HELPER" && cp -r "$ROOT/build/." "$HR_EXT_DIR/$HELPER/"
cp -r "$HERE/probe@hotreload.test" "$HR_EXT_DIR/"
if [ -n "${HR_PREINSTALL:-}" ]; then bash -c "$HR_PREINSTALL"; fi
gsettings set org.gnome.shell welcome-dialog-last-shown-version '99.0'
gsettings set org.gnome.shell enabled-extensions "['$HELPER', 'probe@hotreload.test'${HR_ENABLED:+, $HR_ENABLED}]"

gnome-shell --headless --virtual-monitor 1280x800 >"$HR_LOG" 2>&1 &
export HR_SHELL_PID=$!
trap 'kill $HR_SHELL_PID 2>/dev/null; wait $HR_SHELL_PID 2>/dev/null; fusermount3 -u "$HR_RT/doc" 2>/dev/null; rm -rf "$HR_RT"' EXIT

probe() {
  gdbus call --session --dest org.gnome.Shell --object-path /test/hotreload/Probe \
    --method test.hotreload.Probe.Eval "$1"
}
for _ in $(seq 60); do
  sleep 0.5
  probe 'return 1' >/dev/null 2>&1 && break
done
if ! kill -0 $HR_SHELL_PID 2>/dev/null; then
  echo "headless shell did not come up, see $HR_LOG"; tail -20 "$HR_LOG"; exit 1
fi

# Bus-activated windows (prefs) belong on the headless shell.
dbus-update-activation-environment \
  WAYLAND_DISPLAY="$(probe "return GLib.getenv('WAYLAND_DISPLAY')" | sed -E "s/^\\('\"?//; s/\"?',\\)$//")"

"$@"
RC=$?
echo "--- shell log ---"
grep -E "JS ERROR|CRITICAL|Hot Reload" "$HR_LOG" | cut -c1-240 | head -${HR_LOG_LINES:-40}
exit $RC
