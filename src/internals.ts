// Everything this extension relies on that is not public GNOME Shell API.
// If one of these goes away the extension switches itself off rather than half-working.
import type Gio from 'gi://Gio'

import * as Main from 'resource:///org/gnome/shell/ui/main.js'

export interface ShellExtension {
  uuid: string
  dir: Gio.File
  path: string
  type: number
  state: number
  error: string
  /** Set once the shell imported extension.js; from then on its modules are cached by path. */
  isImported?: boolean
  /** A newer version from extensions.gnome.org is downloaded and waits for the next login. */
  hasUpdate?: boolean
  stateObj?: { disable(): void }
}

interface ExtensionManager {
  lookup(uuid: string): ShellExtension | undefined
  getUuids(): string[]
  unloadExtension(extension: ShellExtension): Promise<boolean>
  createExtensionObject(uuid: string, dir: Gio.File, type: number): ShellExtension
  loadExtension(extension: ShellExtension): Promise<void>
  /** uuid -> metadata.version of what was loaded before; loadExtension refuses any other version. */
  _unloadedExtensions: Map<string, unknown>
  /** Active extensions in the order they were enabled. Optional: without it reloads still work. */
  _extensionOrder?: string[]
  /** Set while the shell's "updates are ready to be installed" notification is up. */
  _updateNotified?: boolean
  connect(signal: 'extension-state-changed', handler: (manager: unknown, extension: ShellExtension) => void): number
  disconnect(id: number): void
}

export const extensionManager = Main.extensionManager as unknown as ExtensionManager

export function missingInternals(): string[] {
  const manager = extensionManager as unknown as Record<string, unknown>
  const missing = ['lookup', 'getUuids', 'unloadExtension', 'createExtensionObject', 'loadExtension'].filter(
    (name) => typeof manager[name] !== 'function',
  )
  if (!(manager._unloadedExtensions instanceof Map)) missing.push('_unloadedExtensions')
  return missing
}
