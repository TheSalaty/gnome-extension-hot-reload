import Gio from 'gi://Gio'
import GLib from 'gi://GLib'

import { ExtensionType } from 'resource:///org/gnome/shell/misc/extensionUtils.js'

import { entries } from './files.js'

const QUIET_MS = 400

export interface Source {
  dir: Gio.File
  type: number
}

/**
 * Watches every installed extension's files and reports a UUID once its directory has been
 * quiet for a moment, so an install that rewrites many files causes one reload.
 */
export class Watcher {
  readonly #roots: Source[] = []
  readonly #rootMonitors: Gio.FileMonitor[] = []
  readonly #treeMonitors = new Map<string, Gio.FileMonitor[]>()
  readonly #timers = new Map<string, number>()
  readonly #onChange: (uuid: string) => void

  constructor(onChange: (uuid: string) => void) {
    this.#onChange = onChange
    // Same order as the shell: the user's copy shadows a system-wide one.
    if (global.settings.get_boolean('allow-extension-installation'))
      this.#addRoot(GLib.build_filenamev([global.userdatadir, 'extensions']), ExtensionType.PER_USER)
    for (const dataDir of GLib.get_system_data_dirs())
      this.#addRoot(GLib.build_filenamev([dataDir, 'gnome-shell', 'extensions']), ExtensionType.SYSTEM)
  }

  #addRoot(path: string, type: number): void {
    const dir = Gio.File.new_for_path(path)
    if (!dir.query_exists(null)) return
    this.#roots.push({ dir, type })
    // Sees an extension directory being replaced as a whole, which kills the monitors inside it.
    const monitor = dir.monitor_directory(Gio.FileMonitorFlags.NONE, null)
    monitor.connect('changed', (_monitor, file) => this.#touched(file.get_basename()!))
    this.#rootMonitors.push(monitor)
  }

  /** UUIDs of all installed extensions. */
  installed(): string[] {
    const uuids = new Set<string>()
    for (const { dir } of this.#roots) {
      const children = dir.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null)
      for (const info of children) uuids.add(info.get_name())
    }
    return [...uuids]
  }

  source(uuid: string): Source | null {
    for (const { dir, type } of this.#roots) {
      const child = dir.get_child(uuid)
      if (child.query_file_type(Gio.FileQueryInfoFlags.NONE, null) === Gio.FileType.DIRECTORY)
        return { dir: child, type }
    }
    return null
  }

  /**
   * Watches all directories of the extension and returns a fingerprint of its files
   * (paths, sizes, modification times).
   */
  scan(uuid: string, dir: Gio.File): string {
    this.#treeMonitors.get(uuid)?.forEach((monitor) => monitor.cancel())
    const monitors: Gio.FileMonitor[] = []
    const watch = (directory: Gio.File, relevant: (file: Gio.File) => boolean = () => true): void => {
      const monitor = directory.monitor_directory(Gio.FileMonitorFlags.NONE, null)
      monitor.connect('changed', (_monitor, file) => relevant(file) && this.#touched(uuid))
      monitors.push(monitor)
    }
    const lines: string[] = []
    try {
      // An extension symlinked from a build directory: when that directory is replaced as a
      // whole, only its parent notices.
      const link = dir.query_info(
        'standard::is-symlink,standard::symlink-target',
        Gio.FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
        null,
      )
      if (link.get_is_symlink()) {
        const resolved = dir.get_parent()!.resolve_relative_path(link.get_symlink_target()!)
        const name = resolved.get_basename()
        watch(resolved.get_parent()!, (file) => file.get_basename() === name)
      }
      watch(dir)
      for (const { file, info: entry, path, isDirectory } of entries(dir)) {
        if (isDirectory) {
          watch(file)
        } else {
          const modified = entry.get_attribute_uint64('time::modified')
          const usec = entry.get_attribute_uint32('time::modified-usec')
          lines.push(`${path} ${entry.get_size()} ${modified}.${usec}`)
        }
      }
    } catch (error) {
      // Files vanish under us while an install is running; the next event brings us back.
      console.debug(`Hot Reload: scanning ${uuid}: ${String(error)}`)
    }
    this.#treeMonitors.set(uuid, monitors)
    return GLib.compute_checksum_for_string(GLib.ChecksumType.MD5, lines.sort().join('\n'), -1)!
  }

  #touched(uuid: string): void {
    const pending = this.#timers.get(uuid)
    if (pending !== undefined) GLib.source_remove(pending)
    this.#timers.set(
      uuid,
      GLib.timeout_add(GLib.PRIORITY_DEFAULT, QUIET_MS, () => {
        this.#timers.delete(uuid)
        this.#onChange(uuid)
        return GLib.SOURCE_REMOVE
      }),
    )
  }

  destroy(): void {
    for (const timer of this.#timers.values()) GLib.source_remove(timer)
    this.#timers.clear()
    for (const monitor of this.#rootMonitors) monitor.cancel()
    for (const monitors of this.#treeMonitors.values()) monitors.forEach((monitor) => monitor.cancel())
    this.#treeMonitors.clear()
  }
}
