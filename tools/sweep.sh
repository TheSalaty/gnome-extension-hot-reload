#!/bin/bash
# Compatibility sweep: enables each given extension in the sandbox, reloads it twice and
# reports whether it is still active. Extensions are copied into the sandbox first.
#   tools/sweep.sh <dir with extensions> <uuid>...
#   HR_SWEEP_SYSTEM=1 tools/sweep.sh -      (all system-wide extensions)
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "${HR_PRIVATE_BUS:-}" ]; then
  [ "$1" != - ] && export HR_PREINSTALL="cp -rLn '$1'/. \"\$HR_EXT_DIR/\""
  exec "$HERE/sandbox.sh" "$0" "$@"
fi
shift
ev() {
  gdbus call --session --dest org.gnome.Shell --object-path /test/hotreload/Probe --timeout 60 \
    --method test.hotreload.Probe.Eval "$1" | sed -e "s/^('//" -e "s/',)$//" -e 's/\\\\/\\/g'
}
helper() {
  gdbus call --session --dest org.gnome.Shell --object-path /io/github/thesalaty/HotReload --timeout 60 \
    --method io.github.thesalaty.HotReload."$@" | sed -e "s/^('//" -e "s/',)$//" -e 's/\\\\/\\/g'
}
state() { ev "const e = Main.extensionManager.lookup('$1'); return e ? e.state + (e.error ? ' ' + e.error.split(String.fromCharCode(10))[0].slice(0, 120) : '') : 'unknown'" | tr -d '"'; }
errors() { grep -c "JS ERROR\|CRITICAL" "$HR_LOG"; }
[ -n "${HR_SWEEP_SYSTEM:-}" ] && set -- $(ls /usr/share/gnome-shell/extensions)
sleep 4; PASS=0; FAIL=0
for U in "$@"; do
  E0=$(errors)
  gnome-extensions enable "$U" 2>/dev/null; sleep 2
  BEFORE=$(state "$U")
  if [ "${BEFORE%% *}" != 1 ]; then echo "skip  $U (does not start in the sandbox: $BEFORE)"; gnome-extensions disable "$U" 2>/dev/null; sleep 0.5; continue; fi
  E1=$(errors)
  R1=$(helper Reload "$U"); sleep 1.5; R2=$(helper Reload "$U"); sleep 1.5
  AFTER=$(state "$U"); E2=$(errors)
  if [[ $R1 == *'"ok":true'* && $R2 == *'"ok":true'* && $AFTER == 1 ]]; then
    echo "ok    $U  (log errors: $((E1 - E0)) on enable, $((E2 - E1)) during 2 reloads)"; PASS=$((PASS + 1))
  else
    echo "FAIL  $U  state=$AFTER"; echo "        $R1" | cut -c1-300; echo "        $R2" | cut -c1-300; FAIL=$((FAIL + 1))
  fi
  gnome-extensions disable "$U"; sleep 1
done
echo; echo "$PASS ok, $FAIL failed"
