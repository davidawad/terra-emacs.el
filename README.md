# terra-emacs

Declarative configuration for Emacs workspaces, in the manner of
terraform. A state file says which workspaces exist and how each is laid
out. terra-emacs reads one, **plans** what converging on it would
change, and **applies** it. Applying is idempotent: a second apply plans
nothing. Windows, terminals with their commands, and Claude Code
sessions (resumed by session id) all come back as they were.

terra-emacs is the engine. Its companion,
[terra-emacs-capture](https://github.com/davidawad/terra-emacs-capture.el),
is the exporter: it captures any live workspace, or the whole set, and
writes it out as a state file for this engine, and its autosave mode
keeps one current so a restart changes nothing. You can also write state
files by hand.

Pure Emacs Lisp, Emacs 29.1 or later, no dependencies. eat, vterm and
persp-mode are used when present.

## Install

Emacs 30 and later, with `package-vc`:

```elisp
(package-vc-install "https://github.com/davidawad/terra-emacs.el")
(require 'terra-emacs)
(terra-emacs-apply "~/layouts/work.eld")
```

To capture state files from a live Emacs, install the exporter too:

```elisp
(package-vc-install "https://github.com/davidawad/terra-emacs-capture.el")
(require 'terra-emacs-capture)
(terra-emacs-capture-autosave-mode 1)   ; save on exit, restore at start
```

Emacs 29.1, or by hand: clone the repository and put it on `load-path`.

```elisp
(add-to-list 'load-path "~/src/terra-emacs.el")
(require 'terra-emacs)
```

With `use-package` (Emacs 30):

```elisp
(use-package terra-emacs
  :vc (:url "https://github.com/davidawad/terra-emacs.el"))
```

## Commands

| Command | Does |
|---|---|
| `terra-emacs-plan STATE` | the steps that would converge on STATE, as data (and shown in `*terra-emacs-plan*` when called interactively) |
| `terra-emacs-apply STATE [DRY-RUN]` | perform them; returns the plan, nil when nothing changed |
| `terra-emacs-apply-set NAME` | converge on the named set `NAME.eld` in `terra-emacs-directory` |
| `terra-emacs-restore-at-start` | apply the set `terra-emacs-autosave-name` once Emacs has a frame (in a daemon, its first client frame), once per Emacs |
| `terra-emacs-restore-autosave` | converge on that set now |

STATE is a state plist or a state file name. `terra-emacs-write-state`
and `terra-emacs-read-state` handle the files.

```elisp
;; Dry run: what would change, and nothing changes.
(terra-emacs-apply "~/layouts/work.eld" t)
;; => the steps, for example
;;    ((:op create :ws "notes" :id "0a9e77c1d2e3")
;;     (:op layout :ws "notes" :layout (...) :why missing))
(terra-emacs-apply "~/layouts/work.eld")   ; do it
(terra-emacs-apply "~/layouts/work.eld")   ; => nil: nothing left to do
```

`M-x terra-emacs-plan` and `M-x terra-emacs-apply` (with `C-u` for a
dry run) read a file name and show the plan in `*terra-emacs-plan*`.

## The format

A state is one readable s-expression (`lisp-data-mode`):

```elisp
;; terra-emacs state -*- mode: lisp-data -*-
(:terra-emacs 1                         ; format version
 :backend tab-bar                       ; where it was captured (informational)
 :levels ((:id "ops" :name "Operations") (:id "home" :name "Home"))
 :current "code"                        ; the workspace shown
 :workspaces                            ; in display order
 ((:name "code" :id "6f1c09a2b3d4" :level "ops"
   :layout
   (:split right :sizes (0.5 0.5)
    :children
    ((:leaf ("init.el" (filename . "~/src/init.el") (position . 1)
                       (buffer-name . "init.el"))
      :selected t)
     (:split below :sizes (0.6 0.4)
      :children
      ((:leaf ("*claude*" (handler . terra-emacs-claude-bookmark-handler)
                          (buffer-name . "*claude*")
                          (session-id . "ce20793a-...") (cwd . "~/src/")
                          (argv "claude" "--model" "opus")
                          (env ("CLAUDE_CONFIG_DIR" . "~/.claude"))))
       (:leaf ("*shell*" (handler . terra-emacs-eat-bookmark-handler)
                         (buffer-name . "*shell*") (cwd . "~/src/")
                         (argv "/bin/zsh"))))))))
  (:name "notes" :id "0a9e77c1d2e3" :level "home"
   :layout (:leaf ("notes.org" (filename . "~/notes.org"))))
  (:name "scratch")))                   ; no :layout: left as it is laid out
```

- **Workspaces** match by `:id` first, then by `:name`. A workspace whose
  id is found under another name is renamed. One the state does not
  name is killed. A missing one is created. Order is list order.
- **Levels** group workspaces. With tab-bar a level is a tab group; with
  persp-mode it is a perspective parameter
  (`terra-emacs-persp-level-parameter`). `:levels` declares their
  names, and `terra-emacs-levels-functions` hears about it.
- **Saved parameters** (`:parameters ((PARAM . VALUE) ...)`) carry
  backend data a workspace should keep across a restart, such as
  another tool's tags. The keys are chosen by
  `terra-emacs-tab-bar-saved-parameters` or
  `terra-emacs-persp-saved-parameters`.
- **`:partial t`** marks a state that names only some workspaces.
  Applying it creates, renames, levels and lays out what it names. It
  kills, moves and selects nothing else.
- **Layouts** are split trees, after kiwanami's window-layout recipes:
  `(:split right|below :sizes SHARES :children NODES)` or
  `(:leaf RECORD [:selected t])`. They fill the frame's main window, so
  side windows are left alone.
- **Leaves** are bookmark records. Any mode with bookmark support
  restores for free. terra-emacs reads `buffer-name`, and an optional
  `terra-key` that overrides the leaf's identity. The identity decides
  whether a window already shows the right thing: the file for a file
  or directory, the session id for Claude Code, buffer name plus
  command for a terminal, else the buffer name.

## Plan and apply

A plan is a list of steps such as `(:op create :ws "notes" :id ...)`,
`(:op rename :ws "code" :to "src")`, `(:op move :ws "mail" :to 0)` and
`(:op layout :ws "code" :layout TREE :why differs)`. A layout is rebuilt
only when its shape or a leaf's identity differs, or a leaf's process
has died. Rebuilding reuses a live buffer for each leaf, so a process
starts only where one is missing.

To compare, the engine observes each live window: the record a capture
handler on `terra-emacs-leaf-capture-functions` gives (terra-emacs-capture
installs them), else the record the engine restored that buffer from,
else the file or directory it visits, else its name. A hidden workspace
is read off the window state its backend keeps (a tab's `ws`, a
perspective's window configuration), so planning shows nothing. On its
own, without the exporter, a second apply of the same file plans
nothing.

## Handlers

| Leaf | Record | Restored |
|---|---|---|
| files, dired, Info, help, ... | a bookmark record | `bookmark-handle-bookmark` (a missing file gives a placeholder, never a prompt) |
| eshell | `terra-emacs-eshell-bookmark-handler`, buffer-name, cwd | the live eshell of that name, else a new one in cwd |
| eat | `terra-emacs-eat-bookmark-handler`, buffer-name, cwd, argv | the live buffer running that argv, else argv re-run in cwd |
| vterm | `terra-emacs-vterm-bookmark-handler`, buffer-name, cwd, command | the same, through `vterm-mode` |
| Claude Code in eat | `terra-emacs-claude-bookmark-handler`, session-id, cwd, argv, env | argv minus `--resume`/`--session-id`/`--continue`, plus `--resume ID`, in eat, with inherited `CLAUDE*`, `CLAUDECODE`, `AGENT_*`, `AWAD_*`, `LOADOUT_*` and `BD_ACTOR` removed from the child env |
| anything else | `terra-emacs-leaf-buffer-handler`, buffer-name | that buffer (created empty if gone) |

A terminal of the same name whose command the engine does not know (one
started by hand, with no exporter recording commands) is reused, never
killed.

Claude sessions never get two writers. When the session file
(`~/.claude/sessions/<pid>.json`) shows the session live and an eat
buffer in this Emacs runs it, that buffer is reused. When it is live
anywhere else, `terra-emacs-claude-view-function` opens a read-only view
instead and says so; a later apply tries again.

A new leaf type needs a bookmark handler that restores its record.
Give the handler a `terra-emacs-leaf-key-function` property (a function
of the record returning its identity) and, when it runs a process, a
non-nil `terra-emacs-leaf-process` property so a dead one is restarted.
Its capture side goes on `terra-emacs-leaf-capture-functions`.

## Backends

`terra-emacs-backend` (or the first available of
`terra-emacs-backend-candidates`) picks one:

- **tab-bar**: a workspace is a tab of the selected frame, and a level
  is its tab group. Ids ride in the tab's alist.
- **persp-mode**: a workspace is a perspective, other than the nil one.
  The level, the id and (optionally,
  `terra-emacs-persp-order-parameter`) the order are perspective
  parameters.

To add one (perspective.el, tabspaces, ...), define the generic
functions in `terra-emacs-backend.el` for `(eql YOUR-BACKEND)`.

## How it builds on Emacs

terra-emacs does not reimplement window or buffer persistence:

- Each window's leaf record rides in the `terra-emacs-leaf` window
  parameter, which is listed in `window-persistent-parameters` (as
  activities.el does). Layouts are read off `window-state-get` WRITABLE.
- Apply turns the tree into a window state for `window-state-put`.
- Leaves are bookmark records, restored by `bookmark-handle-bookmark`.

A window state names buffers by name. A hidden workspace whose buffer
was killed while it was hidden comes back without that window (Emacs
30's default `window-restore-killed-buffer-windows`), or with it showing
some other buffer, often the one its neighbour shows, when that option
keeps such windows. That is `window-state-put`, not terra-emacs; a
plan sees the difference and an apply rebuilds the layout.

## Prior art

| Tool | Captures | Restores | Declarative file, diff, plan | Terminals with their command | Claude session by id |
|---|---|---|---|---|---|
| desktop.el | buffers, frames (frameset) | replay at start | no | no | no |
| frameset | frames and window states | `frameset-restore` | no | no | no |
| burly | window configs as bookmarks | replay | no | no | no |
| activities.el | per-activity window state + bookmarks | replay, default/last | no | no | no |
| persp-mode, perspective, tabspaces | per-workspace buffers/windows | session file replay | no | no | no |
| easysession, workgroups2 | sessions | replay | no | no | no |
| **terra-emacs** (+ terra-emacs-capture) | the declarative set and layouts, from any live Emacs | idempotent converge | yes: diff, plan, dry run, apply | eat, vterm, eshell (cwd and command) | yes, never two writers |

Everything before it is snapshot and replay. Replaying a snapshot over a
live Emacs duplicates what is already there. terra-emacs instead diffs
the desired state against the live one and changes only the difference,
so the same file serves for start-up, a restart and hand-written
layouts.

## Tests

`test/test_terra_emacs.sh [suite...]` byte-compiles every file with
warnings as errors. It then runs each `test/test-*.el` ERT suite in its
own batch Emacs, one at a time. eat and persp-mode come from
`TERRA_EMACS_TEST_PACKAGES` (default `/opt/emacs-test-packages`) or the
colon-separated directories in `TERRA_EMACS_TEST_LOAD_PATH`; tests
needing one skip without it. The capture round trip (capture, state
file, apply, capture again) lives in terra-emacs-capture's suite.

`make test` runs the same script.

## License

MIT. See [LICENSE](LICENSE).
