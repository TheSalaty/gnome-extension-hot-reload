#!/bin/bash
# Erzeugt eine Variante der Dummy-Extension.
#   tools/mkdummy.sh <zielordner> <TAG> <css-farbe> [version] [extra]
# extra: "newkey"   Schema bekommt einen zusätzlichen Schlüssel
#        "broken"   Syntaxfehler im Untermodul
#        "gtname"   Klasse mit fest vergebenem GTypeName
#        "throws"   enable() wirft
#        "throwslate" enable() wirft, nachdem der Panel-Button schon hängt
# HR_UUID wählt eine andere UUID (und damit Panel-Rolle).
set -eu
OUT=$1; TAG=$2; COLOR=$3; VERSION=${4:-1}; EXTRA=${5:-}
UUID=${HR_UUID:-dummy@hotreload.test}; ROLE=hr-${UUID%%@*}; CLS=${UUID%%@*}
D="$OUT/$UUID"
rm -rf "$D"; mkdir -p "$D/lib/deep" "$D/schemas"

cat > "$D/metadata.json" <<JSON
{
  "uuid": "$UUID",
  "name": "HR Dummy $TAG",
  "description": "Testobjekt",
  "version": $VERSION,
  "settings-schema": "org.gnome.shell.extensions.hr-dummy",
  "shell-version": ["45", "46", "47", "48", "49", "50", "51"]
}
JSON

NEWKEY=""; NEWKEY_READ="''"
if [ "$EXTRA" = newkey ]; then
  NEWKEY='<key name="extra" type="s"><default>"extra-'$TAG'"</default></key>'
  NEWKEY_READ="' extra=' + this._settings.get_string('extra')"
fi
cat > "$D/schemas/org.gnome.shell.extensions.hr-dummy.gschema.xml" <<XML
<schemalist>
  <schema id="org.gnome.shell.extensions.hr-dummy" path="/org/gnome/shell/extensions/hr-dummy/">
    <key name="greeting" type="s"><default>"default-$TAG"</default></key>
    $NEWKEY
  </schema>
</schemalist>
XML
glib-compile-schemas "$D/schemas"

echo ".$ROLE-label { color: $COLOR; }" > "$D/stylesheet.css"

echo "export const deep = '$TAG';" > "$D/lib/deep/deep.js"

GTNAME=""; [ "$EXTRA" = gtname ] && GTNAME="{GTypeName: 'HrDummyFixedName'}, "
BROKEN=""; [ "$EXTRA" = broken ] && BROKEN="this is not javascript ("
cat > "$D/lib/text.js" <<JS
import GObject from 'gi://GObject';
import {deep} from './deep/deep.js';
$BROKEN
export const Thing = GObject.registerClass(${GTNAME}
class Thing_$CLS extends GObject.Object {
    describe() { return 'thing=$TAG'; }
});

export const libText = () => \`lib=$TAG deep=\${deep} \${new Thing().describe()}\`;
JS

THROWS=""; [ "$EXTRA" = throws ] && THROWS="throw new Error('enable kaputt in $TAG');"
THROWSLATE=""; [ "$EXTRA" = throwslate ] && THROWSLATE="throw new Error('enable fails late in $TAG');"
cat > "$D/extension.js" <<JS
import Clutter from 'gi://Clutter';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';

import {libText} from './lib/text.js';

const MAIN = '$TAG';

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(text) {
        super._init(0.0, '$ROLE');
        this.label = new St.Label({
            text,
            style_class: '$ROLE-label',
            y_align: Clutter.ActorAlign.CENTER,
        });
        this.add_child(this.label);
    }
});

export default class Dummy extends Extension {
    enable() {
        $THROWS
        this._settings = this.getSettings();
        const text = () => \`main=$TAG \${libText()} gs=\${this._settings.get_string('greeting')}\` + $NEWKEY_READ;
        this._indicator = new Indicator(text());
        this._changedId = this._settings.connect('changed',
            () => (this._indicator.label.text = text()));
        Main.panel.addToStatusArea('$ROLE', this._indicator);
        $THROWSLATE
    }

    disable() {
        this._settings.disconnect(this._changedId);
        this._settings = null;
        this._indicator.destroy();
        this._indicator = null;
    }
}
JS

cat > "$D/prefs.js" <<JS
import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

import {deep} from './lib/deep/deep.js';

export default class DummyPrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const text = \`prefs=$TAG deep=\${deep} gs=\${settings.get_string('greeting')} path=\${this.path}\`;
        const page = new Adw.PreferencesPage();
        const group = new Adw.PreferencesGroup({title: text});
        page.add(group);
        window.add(page);
        // Marker für den Test, weil niemand auf das Fenster schaut.
        const marker = GLib.build_filenamev([GLib.get_user_cache_dir(), 'hr-prefs-marker']);
        GLib.file_set_contents(marker, text);
        // Schreibprobe aus dem Prefs-Prozess: muss in der Shell ankommen.
        settings.set_string('greeting', 'from-prefs-$TAG');
        Gio.Settings.sync();
    }
}
JS
