// Gives GObject classes of a reloaded extension a fresh GType name.
//
// GJS names a class "Gjs_<last directory>_<file>_<class>". A reload from a fresh path keeps
// all three, so GObject.registerClass throws "Type name ... is already registered". For
// callers below the reload cache the generation is appended instead.
//
// This file is .mts on purpose: GJS finds the registering file by matching ".js:<line>" in
// the stack, so a frame from an .mjs file is skipped and every extension outside the reload
// cache gets exactly the name it would get without this patch.
import GObject from 'gi://GObject'

type Register = (this: unknown, ...args: unknown[]) => unknown
type Registry = { registerClass: Register; GTypeName: symbol }

export const GENERATION_PREFIX = 'gen-'
const GENERATION = /\/gnome-shell-hot-reload\/gen-([0-9a-z]+)\//
const registry = GObject as unknown as Registry
// Marks our wrapper with what it wraps. When this extension reloads itself, the new copy of
// this module replaces the old wrapper instead of stacking a second one on top.
const WRAPPED = Symbol.for('hot-reload.wrapped')
type Wrapper = Register & { [WRAPPED]?: Register }
let installed = false

function wrap(register: Register): Register {
  const wrapper: Wrapper = function (...args) {
    const caller = new Error().stack?.split('\n')[1] ?? ''
    const generation = caller.match(GENERATION)?.[1]
    if (generation === undefined) return register.apply(this, args)

    const klass = args.at(-1) as { name: string } & Record<symbol, string | undefined>
    const meta = args.length > 1 ? (args[0] as Record<string, unknown>) : {}
    const own = Object.hasOwn(klass, registry.GTypeName) ? klass[registry.GTypeName] : undefined
    const explicit = (meta.GTypeName as string | undefined) ?? own
    // GJS already gives anonymous classes a random name.
    if (explicit === undefined && klass.name === '') return register.apply(this, args)

    const [, dir, file] = caller.match(/([^/]+)\/([^/]+)\.js:\d+/) ?? []
    const base = explicit ?? `Gjs_${dir}_${file}_${klass.name}`
    const name = `${base}_g${generation}`.replace(/[^a-z0-9+_-]/gi, '_')
    if (own !== undefined) {
      klass[registry.GTypeName] = name
      return register.apply(this, args)
    }
    return register.call(this, { ...meta, GTypeName: name }, klass)
  }
  wrapper[WRAPPED] = register
  return wrapper
}

export function install(): void {
  if (installed) return
  installed = true
  // Interfaces are registered through registerClass as well.
  const current: Wrapper = registry.registerClass
  registry.registerClass = wrap(current[WRAPPED] ?? current)
}
