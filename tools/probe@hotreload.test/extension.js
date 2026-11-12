// Test only. Exposes Eval on the sandboxed shell's bus so the tests can look inside it.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import System from 'system';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const IFACE = `
<node><interface name="test.hotreload.Probe">
  <method name="Eval">
    <arg type="s" direction="in" name="code"/>
    <arg type="s" direction="out" name="result"/>
  </method>
</interface></node>`;

const AsyncFunction = (async () => {}).constructor;

export default class Probe extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/test/hotreload/Probe');
    }

    disable() {
        this._dbus.unexport();
        this._dbus = null;
    }

    async EvalAsync([code], invocation) {
        let reply;
        try {
            const fn = new AsyncFunction('Main', 'Gio', 'GLib', 'System', code);
            reply = (await fn(Main, Gio, GLib, System)) ?? null;
        } catch (e) {
            reply = {thrown: `${e}`, stack: e.stack};
        }
        invocation.return_value(new GLib.Variant('(s)', [JSON.stringify(reply)]));
    }
}
