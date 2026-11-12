import Gio from 'gi://Gio'
import GLib from 'gi://GLib'

const ATTRIBUTES = 'standard::name,standard::type,standard::size,time::modified,time::modified-usec'

export interface Entry {
  file: Gio.File
  info: Gio.FileInfo
  /** Path relative to the extension directory. */
  path: string
  isDirectory: boolean
}

/**
 * Everything below an extension directory, parents before children, symlinks followed.
 *
 * Hidden entries and node_modules are left out: an extension symlinked from its repository
 * would otherwise drag .git and its dependencies into every scan and copy.
 */
export function* entries(dir: Gio.File, prefix = ''): Generator<Entry> {
  for (const info of dir.enumerate_children(ATTRIBUTES, Gio.FileQueryInfoFlags.NONE, null)) {
    const name = info.get_name()
    if (name.startsWith('.') || name === 'node_modules') continue
    const file = dir.get_child(name)
    const isDirectory = info.get_file_type() === Gio.FileType.DIRECTORY
    yield { file, info, path: `${prefix}${name}`, isDirectory }
    if (isDirectory) yield* entries(file, `${prefix}${name}/`)
  }
}

export function copyTree(source: Gio.File, target: Gio.File): void {
  target.make_directory_with_parents(null)
  for (const { file, path, isDirectory } of entries(source)) {
    const to = target.resolve_relative_path(path)
    if (isDirectory) to.make_directory(null)
    else file.copy(to, Gio.FileCopyFlags.NONE, null, null)
  }
}

/** Changes only when a file's content, name or presence changes; modification times do not count. */
export function contentHash(dir: Gio.File): string {
  const lines: string[] = []
  for (const { file, path, isDirectory } of entries(dir)) {
    if (isDirectory) continue
    const [bytes] = file.load_bytes(null)
    lines.push(`${path} ${GLib.compute_checksum_for_bytes(GLib.ChecksumType.MD5, bytes)}`)
  }
  return GLib.compute_checksum_for_string(GLib.ChecksumType.MD5, lines.sort().join('\n'), -1)!
}
