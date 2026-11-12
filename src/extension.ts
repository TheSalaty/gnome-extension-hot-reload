import Gio from 'gi://Gio'
import GLib from 'gi://GLib'

import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js'
import * as Main from 'resource:///org/gnome/shell/ui/main.js'

import { contentHash } from './files.js'
import { extensionManager, missingInternals } from './internals.js'
import { clearUnusedCopies, reload, type ReloadResult } from './reloader.js'
import { Watcher } from './watcher.js'

const DBUS_PATH = '/io/github/thesalaty/HotReload'
const DBUS_INTERFACE = `
<node><interface name="io.github.thesalaty.HotReload">
  <method name="Reload">
    <arg type="s" direction="in" name="uuid"/>
    <arg type="s" direction="out" name="result"/>
  </method>
  <method name="Status">
    <arg type="s" direction="out" name="status"/>
  </method>
</interface></node>`

interface Tracked {
  /** Cheap fingerprint (names, sizes, times) of the files as last seen. */
  fingerprint: string
  /** Hash of the file contents that were last loaded or rejected; unknown until the first reload. */
  content?: string
  last?: ReloadResult
}

// Lives outside this instance on purpose. The shell disables this extension on the lock
// screen and enables it again afterwards, and when this extension reloads itself a new copy
// of this module takes over; what was last seen of every extension has to survive both.
// Keep `Tracked` backwards compatible: an older copy of this module may have written it.
const shared = globalThis as unknown as Record<symbol, Map<string, Tracked> | undefined>
const tracked = (shared[Symbol.for('hot-reload.tracked')] ??= new Map<string, Tracked>())

export default class HotReload extends Extension {
  #watcher: Watcher | null = null
  #dbus: Gio.DBusExportedObject | null = null
  #queue: Promise<unknown> = Promise.resolve()

  override enable(): void {
    const missing = missingInternals()
    if (missing.length > 0) {
      const message = `This GNOME Shell version is not supported (missing: ${missing.join(', ')}).`
      console.error(`Hot Reload: ${message}`)
      Main.notify(this.metadata.name, message)
      return
    }

    const watcher = new Watcher((uuid) => this.#enqueue(() => this.#check(uuid, false)))
    this.#watcher = watcher
    this.#enqueue(async () => {
      await clearUnusedCopies()
      // First run records what the shell has loaded; after a lock screen it catches up.
      // One extension per idle slot, so logging in is not held up by the scan.
      for (const uuid of watcher.installed()) {
        await new Promise<void>((resolve) => {
          GLib.idle_add(GLib.PRIORITY_LOW, () => (resolve(), GLib.SOURCE_REMOVE))
        })
        await this.#check(uuid, !tracked.has(uuid))
      }
    })

    this.#dbus = Gio.DBusExportedObject.wrapJSObject(DBUS_INTERFACE, this)
    this.#dbus.export(Gio.DBus.session, DBUS_PATH)
  }

  override disable(): void {
    this.#dbus?.unexport()
    this.#dbus = null
    this.#watcher?.destroy()
    this.#watcher = null
    // Extensions that were reloaded keep running from their copies.
  }

  /** One reload at a time: unloading an extension briefly disables the ones enabled after it. */
  #enqueue<T>(task: () => Promise<T>): Promise<T> {
    const result = this.#queue.then(task)
    this.#queue = result.catch(logError)
    return result
  }

  async #check(uuid: string, baseline: boolean, force = false): Promise<ReloadResult | null> {
    const watcher = this.#watcher
    if (!watcher) return null
    const source = watcher.source(uuid)
    if (!source) return null

    const fingerprint = watcher.scan(uuid, source.dir)
    const entry: Tracked = tracked.get(uuid) ?? { fingerprint: '' }
    tracked.set(uuid, entry)
    // A new install the shell has not seen yet is loaded even on the first run.
    if (baseline && extensionManager.lookup(uuid)) {
      entry.fingerprint = fingerprint
      return null
    }
    if (!force && entry.fingerprint === fingerprint) return null

    // A reinstall of identical files (new times, same bytes) is not worth a reload.
    let content: string
    try {
      content = contentHash(source.dir)
    } catch {
      // Files vanish under us while an install is running; its next event brings us back.
      return null
    }
    if (!force && entry.content === content) {
      entry.fingerprint = fingerprint
      return null
    }

    const result = await reload(uuid, source.dir, source.type)
    // An install that is still copying is simply picked up by its next file event.
    if (result.skipped) return result
    entry.fingerprint = fingerprint
    entry.content = content
    entry.last = result
    if (result.ok) {
      console.log(`Hot Reload: reloaded ${uuid}`)
    } else {
      console.warn(`Hot Reload: ${uuid} failed: ${result.error}`)
      Main.notify(
        this.metadata.name,
        result.rolledBack
          ? `${uuid} failed to load, the previous version is running again.\n${result.error}`
          : `${uuid} failed to load.\n${result.error}`,
      )
    }
    return result
  }

  async ReloadAsync([uuid]: [string], invocation: Gio.DBusMethodInvocation): Promise<void> {
    const result = await this.#enqueue(() => this.#check(uuid, false, true)).catch((error) => ({
      uuid,
      ok: false,
      error: String(error),
    }))
    const reply = result ?? { uuid, ok: false, error: 'not an installed extension' }
    invocation.return_value(new GLib.Variant('(s)', [JSON.stringify(reply)]))
  }

  Status(): string {
    return JSON.stringify(
      Object.fromEntries(
        [...tracked]
          .filter(([, entry]) => entry.last)
          .map(([uuid, entry]) => [uuid, { ...entry.last, path: extensionManager.lookup(uuid)?.path }]),
      ),
    )
  }
}
