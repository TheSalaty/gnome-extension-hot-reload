#!/bin/bash
# End-to-end test in the sandboxed headless shell: file changes must reload extensions,
# broken updates must fall back to the previous version.
HERE=$(cd "$(dirname "$0")" && pwd)
A=dummy@hotreload.test; B=dummyb@hotreload.test; C=dummyc@hotreload.test; D=dummyd@hotreload.test
HELPER=hot-reload@thesalaty.github.io
if [ -z "${HR_PRIVATE_BUS:-}" ]; then
  export HR_PREINSTALL="$HERE/mkdummy.sh \"\$HR_EXT_DIR\" v1 '#ff0000' 1; HR_UUID=$B $HERE/mkdummy.sh \"\$HR_EXT_DIR\" b1 '#ff0000' 1; HR_UUID=$D $HERE/mkdummy.sh \"\$HR_SANDBOX/work/project\" d1 '#ff0000' 1; mkdir \"\$HR_SANDBOX/work/project/$D/.git\" \"\$HR_SANDBOX/work/project/$D/node_modules\"; ln -s \"\$HR_SANDBOX/work/project/$D\" \"\$HR_EXT_DIR/$D\""
  export HR_ENABLED="'$A', '$B', '$D'"
  exec "$HERE/sandbox.sh" "$0" "$@"
fi

W="$HR_SANDBOX/work"; FAILED=0
ev() {
  gdbus call --session --dest org.gnome.Shell --object-path /test/hotreload/Probe --timeout 60 \
    --method test.hotreload.Probe.Eval "$1" | sed -e "s/^('//" -e "s/',)$//" -e 's/\\\\/\\/g'
}
helper() {
  gdbus call --session --dest org.gnome.Shell --object-path /io/github/thesalaty/HotReload --timeout 60 \
    --method io.github.thesalaty.HotReload."$@" | sed -e "s/^('//" -e "s/',)$//" -e 's/\\\\/\\/g'
}
label() { ev "const i = Main.panel.statusArea['${1:-hr-dummy}']; if (!i) return 'NO INDICATOR'; const c = i.label.get_theme_node().get_foreground_color(); return i.label.text + ' color=' + [c.red,c.green,c.blue].join(',')"; }
state() { ev "const e = Main.extensionManager.lookup('${1:-$A}'); return e ? 'state=' + e.state + ' cached=' + e.path.includes('gnome-shell-hot-reload') + ' name=' + e.metadata.name : 'UNKNOWN'"; }
path() { ev "return Main.extensionManager.lookup('${1:-$A}').path" | tr -d '"'; }
panel() { ev "const p = Main.panel; const role = new Map(Object.entries(p.statusArea).map(([r, i]) => [i.container, r])); return p._rightBox.get_children().map(c => role.get(c)).filter(r => r?.startsWith('hr-')).join(' ')" | tr -d '"'; }
generations() { ls "$XDG_CACHE_HOME/gnome-shell-hot-reload" 2>/dev/null | wc -l; }
# expect <what> <pattern> <command...>: polls up to 6 s until the output matches.
expect() {
  local what=$1 pattern=$2 out; shift 2
  for _ in $(seq 30); do
    out=$("$@" 2>&1)
    if [[ $out =~ $pattern ]]; then echo "ok    $what"; return; fi
    sleep 0.2
  done
  echo "FAIL  $what"; echo "        wanted: $pattern"; echo "        got:    $out"; FAILED=$((FAILED + 1))
}
# What an install does: replace the directory as a whole.
install() { rm -rf "$HR_EXT_DIR/$2"; cp -r "$1/$2" "$HR_EXT_DIR/"; }
settle() { sleep 1.6; }

sleep 2
expect "both dummies start from their install directory" 'main=v1 .* color=255,0,0' label
expect "  (B)" 'main=b1' label hr-dummyb
expect "  nothing is copied before the first change" '^0$' generations
PANEL=$(panel); echo "      panel order: $PANEL"

"$HERE/mkdummy.sh" "$W/v2" v2 '#00ff00' 2; install "$W/v2" $A
expect "replacing the directory reloads code, submodules and stylesheet" 'main=v2 lib=v2 deep=v2 thing=v2 .* color=0,255,0' label
expect "  same UUID, active, running from a copy" 'state=1 cached=true name=HR Dummy v2' state
expect "  the extension enabled after it is active again" 'main=b1' label hr-dummyb
expect "  panel items keep their order" "^$PANEL\$" panel
expect "  enabled-extensions is untouched" "^\['$HELPER', 'probe@hotreload.test', '$A', '$B', '$D'\]$" gsettings get org.gnome.shell enabled-extensions

"$HERE/mkdummy.sh" "$HR_EXT_DIR" v3 '#0000ff' 3 newkey
expect "rewriting files in place reloads too, with the new settings key" 'main=v3 .* extra=extra-v3 color=0,0,255' label
expect "  only the current copy is kept" '^1$' generations

BEFORE=$(state); touch "$HR_EXT_DIR/$A"; settle
expect "an event without a changed file does not reload" "^${BEFORE//\"/}\$" bash -c "$(declare -f ev state); A=$A; state | tr -d '\"'"

"$HERE/mkdummy.sh" "$W/v4" v4 '#ff00ff' 4 broken; install "$W/v4" $A; settle
expect "a syntax error in a submodule falls back to the previous version" 'main=v3 .* color=0,0,255' label
expect "  and it is active" 'state=1 cached=true' state
expect "  the failure is reported" '"ok":false.*SyntaxError.*"rolledBack":true' helper Status

"$HERE/mkdummy.sh" "$W/v5" v5 '#ff00ff' 5 throwslate; install "$W/v5" $A; settle
expect "enable() failing after it added its panel button falls back as well" 'main=v3 .* color=0,0,255' label
expect "  only the working copy is kept" '^1$' generations
expect "  panel items keep their order after a fallback" "^$PANEL\$" panel

"$HERE/mkdummy.sh" "$W/v6" v6 '#112233' 6; install "$W/v6" $A
expect "the next good version loads" 'main=v6 .* color=17,34,51' label
expect "  panel items still in their order" "^$PANEL\$" panel

BEFORE=$(path); install "$W/v6" $A; settle
expect "reinstalling identical files (new times, same content) does not reload" "^$BEFORE\$" path

HR_UUID=$B "$HERE/mkdummy.sh" "$W/b2" b2 '#00ff00' 2 broken; install "$W/b2" $B; settle
expect "first reload of B is broken: the old code keeps running from memory" 'main=b1' label hr-dummyb

HR_UUID=$C "$HERE/mkdummy.sh" "$HR_EXT_DIR" c1 '#00ff00' 1
expect "a newly installed extension becomes known to the shell" 'state=6 cached=false' state $C
gnome-extensions enable $C
expect "  and can be enabled right away" 'main=c1' label hr-dummyc

expect "an extension symlinked from a project directory starts" 'main=d1' label hr-dummyd
echo "export const deep = 'd2';" > "$W/project/$D/lib/deep/deep.js"
expect "  a file written in the project reloads it" 'main=d1 lib=d1 deep=d2' label hr-dummyd
touch "$W/project/$D/.git/index" "$W/project/$D/node_modules/x.js"; BEFORE=$(state $D); settle
expect "  .git and node_modules are neither watched nor copied" "^${BEFORE//\"/}\$" bash -c "$(declare -f ev state); state $D | tr -d '\"'"
expect "  (not copied)" '^0$' bash -c "find '$XDG_CACHE_HOME/gnome-shell-hot-reload' -name .git -o -name node_modules | wc -l"
HR_UUID=$D "$HERE/mkdummy.sh" "$W/project" d3 '#00ff00' 3
expect "  the project directory being rebuilt from scratch reloads it" 'main=d3 lib=d3 deep=d3 .* color=0,255,0' label hr-dummyd

gnome-extensions disable $HELPER; sleep 1
"$HERE/mkdummy.sh" "$W/v7" v7 '#445566' 7; install "$W/v7" $A; settle
expect "nothing reloads while the helper is disabled (lock screen)" 'main=v6' label
gnome-extensions enable $HELPER
expect "  it catches up when enabled again" 'main=v7 .* color=68,85,102' label

expect "Reload over D-Bus forces a reload" '"ok":true' helper Reload $A
expect "  of an unknown UUID is refused" '"ok":false' helper Reload nope@hotreload.test

gtype() { ev "return Main.panel.statusArea['$1']?.constructor.\$gtype.name ?? 'NO INDICATOR'" | tr -d '"'; }
echo "// updated" >> "$HR_EXT_DIR/$HELPER/extension.js"
expect "the helper reloads itself when its own files change" 'state=1 cached=true' state $HELPER
expect "  and still answers over D-Bus" "$HELPER.*\"ok\":true" helper Status
"$HERE/mkdummy.sh" "$W/v8" v8 '#778899' 8; install "$W/v8" $A
expect "  and still reloads others" 'main=v8 .* color=119,136,153' label
expect "  reloaded classes get one generation suffix" '^Gjs_dummy_hotreload_test_extension_Indicator_g[0-9a-z]+$' gtype hr-dummy
expect "  what it knew before survives: identical reinstall does not reload" "^$(path)\$" bash -c "rm -rf '$HR_EXT_DIR/$A'; cp -r '$W/v8/$A' '$HR_EXT_DIR/'; sleep 1.6; $(declare -f ev path); A=$A; path"
HR_UUID=dummye@hotreload.test "$HERE/mkdummy.sh" "$HR_EXT_DIR" e1 '#00ff00' 1
expect "  a new extension from its install directory keeps its plain class name" 'state=6' state dummye@hotreload.test
gnome-extensions enable dummye@hotreload.test
expect "    (class name)" '^Gjs_dummye_hotreload_test_extension_Indicator$' gtype hr-dummye
expect "  the cache holds only copies in use" '^3$' generations

echo
[ $FAILED = 0 ] && echo "all passed" || echo "$FAILED failed"
exit $FAILED
