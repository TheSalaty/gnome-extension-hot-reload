# Extension Hot Reload: live reload for GNOME Shell extensions

[![Latest release](https://img.shields.io/github/v/release/TheSalaty/gnome-extension-hot-reload)](https://github.com/TheSalaty/gnome-extension-hot-reload/releases/latest)
[![GNOME Shell 45–50](https://img.shields.io/badge/GNOME%20Shell-45%E2%80%9350-4a86cf?logo=gnome&logoColor=white)](#limits)
[![Wayland](https://img.shields.io/badge/Wayland-supported-ffbc00)](#why-this-is-needed)
[![License: MIT](https://img.shields.io/github/license/TheSalaty/gnome-extension-hot-reload)](LICENSE)

Hot reload for GNOME Shell extension development. This extension reloads other extensions as
soon as their files change. An update, a `make install` or a rebuild takes effect within half a
second, on Wayland, without logging out and without restarting GNOME Shell. It works for any
extension; the extension being reloaded needs no changes.

If the new version fails to load, the previous one is brought back and a notification shows
the error.

## Why this is needed

GNOME Shell keeps extension code in memory. Switching an extension off and on does not read
its files again, and on Wayland the shell cannot be restarted without ending the session, so
an updated extension normally only runs after the next login.

## Install

```sh
make install     # builds and copies to ~/.local/share/gnome-shell/extensions
```

Log out and back in once (the shell only discovers new extensions at login), then:

```sh
gnome-extensions enable hot-reload@thesalaty.github.io
```

Or take the zip from the [latest release](https://github.com/TheSalaty/gnome-extension-hot-reload/releases/latest)
and run `gnome-extensions install hot-reload@thesalaty.github.io.shell-extension.zip`. An Arch
package build is in `packaging/` (`makepkg -si` there).

## What it does

- Watches every installed extension, per-user and system-wide, including ones symlinked from
  a project directory. Hidden entries (`.git`) and `node_modules` are ignored.
- Reloads an extension once its directory has been quiet for 0.4 s, so an install that
  rewrites many files causes one reload. Reinstalling identical files causes none.
- Keeps the same UUID: name, settings, the preferences dialog and the list of enabled
  extensions stay as they are.
- Puts panel items back where they were. A reloaded extension is enabled last and would
  otherwise show up at the far left until the next login.
- Makes a newly installed extension known to the shell, so it can be enabled right away.
- Installs updates from extensions.gnome.org right away. The shell downloads them in the
  background and would only apply them at the next login; the "updates are ready to be
  installed" notification is taken down once they are running.
- Catches up after the lock screen, where the shell switches extensions off.
- Reloads itself the same way when it is updated.

To reload by hand, or to see what happened last:

```sh
gdbus call --session --dest org.gnome.Shell --object-path /io/github/thesalaty/HotReload \
  --method io.github.thesalaty.HotReload.Reload 'some-extension@example.com'
gdbus call --session --dest org.gnome.Shell --object-path /io/github/thesalaty/HotReload \
  --method io.github.thesalaty.HotReload.Status
```

## How it works

GJS caches modules by path, so the changed extension is copied to a fresh directory under
`~/.cache/gnome-shell-hot-reload/` and the shell is told to unload the old one and load the
copy under the same UUID. Only the current copy of each extension is kept, and copies left
from an earlier login are removed.

Two things stand in the way and are handled:

- The shell refuses to load a different `metadata.json` version of an extension it has
  loaded before. That record is cleared before loading.
- GJS names GObject classes after directory, file and class name. A reloaded class would get
  the name of its predecessor and fail to register, so classes from a reloaded copy get the
  copy's generation appended to their type name (`src/gtypePatch.mts`).

All of this uses GNOME Shell internals, which are listed in one place, `src/internals.ts`.
If one of them is missing, the extension says so and stays off.

## Cost

Measured with 45 installed extensions (`tools/perf.sh`):

| | |
|---|---|
| Idle | no measurable CPU time; 481 inotify watches |
| Login | 39 ms of scanning, spread over idle time in slices of at most 5 ms |
| A reload | the shell is busy about as long as for switching that extension off and on (46 ms vs 42 ms for a 25-module extension); copying and hashing take 4 ms of that |
| Memory | 100 to 250 kB per reload stay allocated until logout, because GJS never frees a loaded module |

## Limits

- Other extensions stay untouched during a reload. The shell itself would switch off and on
  every extension enabled after the reloaded one, to keep extensions that patch the same shell
  function stacked in order. If two such extensions misbehave after one of them was reloaded,
  switch the other one off and on once.
- If the first reload of an extension in a session fails, its old code keeps running from
  memory, but stylesheet, settings schema and metadata already come from the new files. From
  the second reload on, the fallback is a complete copy of the previous version.
- An extension whose `disable()` leaves something behind (a timer, a signal handler) leaves it
  behind on every reload, as it does on every manual off and on.
- Only top bar items are put back in place. Anything else whose order depends on when an
  extension was enabled, such as entries in the quick settings menu, may move until the next
  login.
- Tested on GNOME Shell 50. The internals it uses are unchanged in the sources of 45 to 49,
  but it has not been run there.

## FAQ

### How do I reload a GNOME Shell extension without logging out on Wayland?

Install this extension. On Wayland, `Alt+F2` → `r` does not exist and
`gnome-extensions disable` / `enable` keeps the old code in memory. Hot Reload loads the
extension again from its files under the same UUID, so changes show up right away.

### Do I still need a nested shell (`dbus-run-session gnome-shell --nested`) for development?

Not for the edit-and-try loop: the extension reloads in your real session. A nested or
headless shell is still useful for code that can crash the shell.

### Does it work on X11?

Nothing in it depends on Wayland, but it has only been run on Wayland. On X11 the shell can be
restarted, which restarts every extension; Hot Reload reloads only the changed one.

### Does it help users, not only developers?

Yes. Updates from extensions.gnome.org are applied immediately instead of after the next login.

### Which GNOME versions are supported?

GNOME Shell 45 to 50 (ESM extensions); tested on 50. See [Limits](#limits).

## Development

```sh
make build       # tsc
make test        # end-to-end test in a headless shell
tools/perf.sh    # cost at login, idle and per reload
tools/sweep.sh <dir> <uuid>...   # reload real extensions and check they survive
```

The tests start a headless GNOME Shell on a private D-Bus with throwaway XDG directories
(`tools/sandbox.sh`), so the running session, its dconf and its extensions are not touched.

## License

MIT
