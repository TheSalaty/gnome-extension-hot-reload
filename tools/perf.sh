#!/bin/bash
# Measures what the extension costs: at login, while idle, and per reload.
#   tools/perf.sh [dir with more extensions to install (not enable), for a realistic scan]
HERE=$(cd "$(dirname "$0")" && pwd)
A=dummy@hotreload.test; HELPER=hot-reload@thesalaty.github.io
SYSTEM="'apps-menu@gnome-shell-extensions.gcampax.github.com', 'places-menu@gnome-shell-extensions.gcampax.github.com', 'window-list@gnome-shell-extensions.gcampax.github.com', 'workspace-indicator@gnome-shell-extensions.gcampax.github.com', 'system-monitor@gnome-shell-extensions.gcampax.github.com', 'drive-menu@gnome-shell-extensions.gcampax.github.com'"
if [ -z "${HR_PRIVATE_BUS:-}" ]; then
  export HR_PREINSTALL="$HERE/mkdummy.sh \"\$HR_EXT_DIR\" v1 '#ff0000' 1; [ -n '${1:-}' ] && cp -rLn '${1:-}'/. \"\$HR_EXT_DIR/\"; ${HR_PERF_PREINSTALL:-true}"
  export HR_ENABLED="'$A', $SYSTEM${HR_PERF_ENABLED:+, $HR_PERF_ENABLED}"
  exec "$HERE/sandbox.sh" "$0" "$@"
fi
ev() {
  gdbus call --session --dest org.gnome.Shell --object-path /test/hotreload/Probe --timeout 120 \
    --method test.hotreload.Probe.Eval "$1" | sed -e "s/^('//" -e "s/',)$//" -e 's/\\\\/\\/g'
}
MODS="const dir = Main.extensionManager.lookup('$HELPER').dir; const load = n => import(dir.get_child(n).get_uri()); const ms = () => GLib.get_monotonic_time() / 1000;"
# Runs \$1 (async JS) and reports wall time plus the longest time the main loop was stuck.
STALL="let last = ms(), stall = 0; const tick = GLib.timeout_add(GLib.PRIORITY_HIGH, 1, () => { const now = ms(); stall = Math.max(stall, now - last); last = now; return true; }); const t0 = ms();"
STALL_END="await new Promise(r => GLib.timeout_add(GLib.PRIORITY_LOW, 5, () => (r(), false))); GLib.source_remove(tick); return {wall_ms: Math.round(ms() - t0 - 5), longest_stall_ms: Math.round(stall)};"
reload_timed() { ev "$MODS const bus = Gio.DBus.session; $STALL await new Promise(r => bus.call('org.gnome.Shell', '/io/github/thesalaty/HotReload', 'io.github.thesalaty.HotReload', 'Reload', new GLib.Variant('(s)', ['$1']), null, 0, -1, null, () => r())); $STALL_END"; }
sleep 6

echo "== login: scanning and watching every installed extension"
ev "$MODS const {Watcher} = await load('watcher.js'); const w = new Watcher(() => {}); const t0 = ms(); let worst = ['', 0], n = 0;
    for (const uuid of w.installed()) { const s = w.source(uuid); if (!s) continue; const t = ms(); w.scan(uuid, s.dir); n++; if (ms() - t > worst[1]) worst = [uuid, Math.round((ms() - t) * 10) / 10]; }
    const total = Math.round((ms() - t0) * 10) / 10; w.destroy(); return {extensions: n, total_ms: total, slowest: worst}"
echo "inotify watches held by the shell: $(cat /proc/$HR_SHELL_PID/fdinfo/* 2>/dev/null | grep -c '^inotify wd')"

echo "== login: longest time the main loop is stuck while the helper starts (400 ms window)"
WINDOW="await new Promise(r => GLib.timeout_add(GLib.PRIORITY_LOW, 400, () => (r(), false))); GLib.source_remove(tick); return Math.round(stall) + ' ms'"
gnome-extensions disable $HELPER; sleep 1
echo "control, nothing happening: $(ev "$MODS $STALL $WINDOW")"
echo "helper starting:            $(ev "$MODS $STALL Main.extensionManager.enableExtension('$HELPER'); $WINDOW")"
sleep 2

echo "== idle: CPU time of the shell over 20 s, helper enabled vs disabled"
cpu() { awk '{print $14 + $15}' /proc/$HR_SHELL_PID/stat; }
C0=$(cpu); sleep 20; C1=$(cpu); gnome-extensions disable $HELPER; sleep 2; C2=$(cpu); sleep 20; C3=$(cpu); gnome-extensions enable $HELPER; sleep 2
echo "enabled: $((C1 - C0)) ticks, disabled: $((C3 - C2)) ticks (1 tick = 10 ms)"

echo "== a file event that changes nothing (touch): cost of the re-scan"
ev "$MODS const {Watcher} = await load('watcher.js'); const w = new Watcher(() => {}); const s = w.source('$A'); const t = ms(); for (let i = 0; i < 100; i++) w.scan('$A', s.dir); const r = (ms() - t) / 100; w.destroy(); return {scan_ms: Math.round(r * 100) / 100}"

echo "== reload of the dummy, 6 extensions enabled after it (first reload re-enables them)"
echo "first reload: $(reload_timed $A)"
echo "order now: $(ev "return Main.extensionManager._extensionOrder.map(u => u.split('@')[0])")"
echo "second reload (nothing enabled after it any more): $(reload_timed $A)"
echo "third reload: $(reload_timed $A)"

for U in ${HR_PERF_RELOAD:-}; do
  echo "== reload of $U ($(du -shL "$HR_EXT_DIR/$U" | cut -f1), $(find -L "$HR_EXT_DIR/$U" -type f | wc -l) files)"
  echo "first:  $(reload_timed $U)"; echo "second: $(reload_timed $U)"
  echo "plain disable + enable, for comparison: $(ev "$MODS const em = Main.extensionManager; $STALL await (em._callExtensionDisableWithRebase ?? em._callExtensionDisable).call(em, '$U'); await em._callExtensionEnable('$U'); $STALL_END")"
  echo "content hash: $(ev "$MODS const {contentHash} = await load('files.js'); const t = ms(); contentHash(Gio.File.new_for_path('$HR_EXT_DIR/$U')); return Math.round((ms() - t) * 10) / 10 + ' ms'")"
  echo "copy alone: $(ev "$MODS const {copyTree} = await load('files.js'); const src = Gio.File.new_for_path('$HR_EXT_DIR/$U'); const t = ms(); await copyTree(src, Gio.File.new_for_path('$HR_SANDBOX/work/copy-$U')); return Math.round(ms() - t) + ' ms'")"
done
