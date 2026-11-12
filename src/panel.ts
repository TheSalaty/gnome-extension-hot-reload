import type Clutter from 'gi://Clutter'

import * as Main from 'resource:///org/gnome/shell/ui/main.js'

interface Panel {
  statusArea: Record<string, { container: Clutter.Actor } | undefined>
  _leftBox?: Clutter.Actor
  _centerBox?: Clutter.Actor
  _rightBox?: Clutter.Actor
}

/**
 * Remembers where every panel item sits and returns a function that puts them back.
 *
 * A reloaded extension is enabled last, and the shell inserts new panel items at the front,
 * so without this its button jumps to the far left until the next login.
 */
export function rememberPanelOrder(): () => void {
  const panel = Main.panel as unknown as Panel
  const boxes = [panel._leftBox, panel._centerBox, panel._rightBox].filter((box) => box !== undefined)
  // Items are recreated by a reload, so they are identified by their role, not by actor.
  const roles = (): Map<Clutter.Actor, string> =>
    new Map(Object.entries(panel.statusArea).flatMap(([role, item]) => (item ? [[item.container, role]] : [])))

  const before = roles()
  const remembered = boxes.map((box) =>
    box.get_children().flatMap((child) => before.get(child) ?? []),
  )

  return () => {
    const now = roles()
    boxes.forEach((box, index) => {
      const children = box.get_children()
      const byRole = new Map(children.flatMap((child) => (now.has(child) ? [[now.get(child)!, child]] : [])))
      // Items that were there before swap places among themselves; anything else stays put.
      const wanted = remembered[index]!.filter((role) => byRole.has(role))
      const movable = new Set(wanted)
      let next = 0
      children
        .map((child) => (movable.has(now.get(child) ?? '') ? byRole.get(wanted[next++]!)! : child))
        .forEach((child, position) => box.set_child_at_index(child, position))
    })
  }
}
