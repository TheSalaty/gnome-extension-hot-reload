import Gio from 'gi://Gio'
import GLib from 'gi://GLib'

import { ExtensionState } from 'resource:///org/gnome/shell/misc/extensionUtils.js'

import { copyTree } from './files.js'
import * as GTypePatch from './gtypePatch.mjs'
import { extensionManager, type ShellExtension } from './internals.js'
import { rememberPanelOrder } from './panel.js'

// Must match the pattern in gtypePatch.mts.
const CACHE = GLib.build_filenamev([GLib.get_user_cache_dir(), 'gnome-shell-hot-reload'])
let generations = 0

export interface ReloadResult {
  uuid: string
  /** The new files are what is running now. */
  ok: boolean
  state: number
  /** Why the new files were rejected. */
  error?: string
  /** The files are not loadable yet (an install is still copying); nothing was touched. */
  skipped?: boolean
  /** The new files failed and the previous version is running again. */
  rolledBack?: boolean
}

function run(argv: string[]): Promise<void> {
  const process = Gio.Subprocess.new(argv, Gio.SubprocessFlags.STDERR_PIPE)
  return new Promise((resolve, reject) => {
    process.communicate_utf8_async(null, null, (_process, result) => {
      try {
        const [, , stderr] = process.communicate_utf8_finish(result)
        if (process.get_successful()) resolve()
        else reject(new Error(stderr?.trim() || `${argv[0]} failed`))
      } catch (error) {
        reject(error)
      }
    })
  })
}

/** The gen-* directory a loaded extension lives in, if it was loaded from the reload cache. */
function generationRoot(path: string): string | null {
  const prefix = `${CACHE}/${GTypePatch.GENERATION_PREFIX}`
  if (!path.startsWith(prefix)) return null
  return path.slice(0, path.indexOf('/', prefix.length))
}

/** Removes copies nothing is loaded from, such as the ones left over from the previous login. */
export async function clearUnusedCopies(): Promise<void> {
  const inUse = new Set(
    extensionManager.getUuids().map((uuid) => generationRoot(extensionManager.lookup(uuid)?.path ?? '')),
  )
  const cache = Gio.File.new_for_path(CACHE)
  if (!cache.query_exists(null)) return
  for (const info of cache.enumerate_children('standard::name', Gio.FileQueryInfoFlags.NONE, null)) {
    const path = GLib.build_filenamev([CACHE, info.get_name()])
    if (!inUse.has(path)) await run(['rm', '-rf', path]).catch(logError)
  }
}

/** Why `source` cannot be loaded as `uuid`, or null. Checked before the running version is touched. */
export function unloadableReason(uuid: string, source: Gio.File): string | null {
  if (!source.get_child('extension.js').query_exists(null)) return 'extension.js is missing'
  try {
    const [, contents] = source.get_child('metadata.json').load_contents(null)
    const metadata = JSON.parse(new TextDecoder().decode(contents)) as Record<string, unknown>
    if (metadata.uuid !== uuid) return `metadata.json is for "${String(metadata.uuid)}"`
    for (const key of ['name', 'description', 'shell-version'])
      if (!metadata[key]) return `metadata.json has no "${key}"`
  } catch (error) {
    return `metadata.json is unreadable: ${String(error)}`
  }
  return null
}

function copyToCache(uuid: string, source: Gio.File): Gio.File {
  const generation = `${Date.now().toString(36)}${(++generations).toString(36)}`
  // The last directory has to be the UUID, and the shell's gettext lookup searches the
  // stack for "/gnome-shell/extensions/".
  const target = Gio.File.new_for_path(
    GLib.build_filenamev([
      CACHE,
      `${GTypePatch.GENERATION_PREFIX}${generation}`,
      'gnome-shell',
      'extensions',
      uuid,
    ]),
  )
  copyTree(source, target)
  return target
}

async function load(uuid: string, dir: Gio.File, type: number): Promise<ShellExtension | undefined> {
  // Otherwise the shell refuses any other metadata.version than the one it loaded first.
  extensionManager._unloadedExtensions.delete(uuid)
  try {
    await extensionManager.loadExtension(extensionManager.createExtensionObject(uuid, dir, type))
  } catch (error) {
    logError(error as object, `Hot Reload: loading ${uuid}`)
  }
  return extensionManager.lookup(uuid)
}

/**
 * Makes the shell run `uuid` from the files in `source`.
 *
 * The files are loaded from a fresh copy, because GJS caches modules by path. If they fail
 * to load, the previous version is brought back.
 */
export async function reload(uuid: string, source: Gio.File, type: number): Promise<ReloadResult> {
  const reason = unloadableReason(uuid, source)
  if (reason !== null)
    return { uuid, ok: false, state: extensionManager.lookup(uuid)?.state ?? 0, error: reason, skipped: true }

  const previous = extensionManager.lookup(uuid)
  // Nothing of it is cached yet, so its own directory is as good as a copy.
  if (!previous?.isImported) {
    if (previous) await extensionManager.unloadExtension(previous)
    const loaded = await load(uuid, source, previous?.type ?? type)
    const state = loaded?.state ?? ExtensionState.ERROR
    return { uuid, ok: state !== ExtensionState.ERROR, state, error: loaded?.error || undefined }
  }

  let dir: Gio.File
  try {
    dir = copyToCache(uuid, source)
  } catch (error) {
    return { uuid, ok: false, state: previous.state, error: `copy failed: ${String(error)}`, skipped: true }
  }

  // Stays installed for good: extensions keep running from their copies after this
  // extension is disabled, and may still register classes then.
  GTypePatch.install()
  const previousRoot = generationRoot(previous.path)
  const restorePanelOrder = rememberPanelOrder()
  await extensionManager.unloadExtension(previous)
  const loaded = await load(uuid, dir, previous.type)
  if (loaded && loaded.state !== ExtensionState.ERROR) {
    restorePanelOrder()
    if (previousRoot !== null) run(['rm', '-rf', previousRoot]).catch(logError)
    return { uuid, ok: true, state: loaded.state }
  }

  const error = loaded?.error || 'could not be loaded'
  if (loaded) {
    // A half-finished enable() leaves actors behind that would block the previous version,
    // for example the panel role.
    try {
      loaded.stateObj?.disable()
    } catch {
      // It never got fully enabled, so a failing disable() is expected.
    }
    await extensionManager.unloadExtension(loaded)
  }
  // The previous modules are still cached under their path, so this runs the old code even
  // if its files were overwritten in place.
  const restored = await load(uuid, previous.dir, previous.type)
  restorePanelOrder()
  run(['rm', '-rf', generationRoot(dir.get_path()!)!]).catch(logError)
  const state = restored?.state ?? ExtensionState.ERROR
  return { uuid, ok: false, state, error, rolledBack: state !== ExtensionState.ERROR }
}
