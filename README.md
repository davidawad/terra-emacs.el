# terra-emacs

Declarative configuration for Emacs workspaces, in the manner of
terraform. A state file says which workspaces exist and how each is laid
out. terra-emacs can **capture** that state from any live Emacs,
**plan** what converging on a state would change, and **apply** it.
Applying is idempotent: a second apply plans nothing. Run with
`terra-emacs-autosave-mode` on, a restart changes nothing. Windows,
terminals with their commands, and Claude Code sessions (by session id)
all come back as they were.

Pure Emacs Lisp, Emacs 29.1 or later, no dependencies. eat, vterm and
persp-mode are used when present.

## Commands

| Command | Does |
|---|---|
| `terra-emacs-capture-all` | the full state: levels, every workspace in order, each layout |
| `terra-emacs-capture` | one workspace's state |
| `terra-emacs-plan STATE` | the steps that would converge on STATE, as data (and shown in `*terra-emacs-plan*` when called interactively) |
| `terra-emacs-apply STATE [DRY-RUN]` | perform them; returns the plan, nil when nothing changed |
| `terra-emacs-save NAME` / `terra-emacs-apply-set NAME` | named sets, `NAME.eld` in `terra-emacs-directory` |
| `terra-emacs-autosave-mode` | save on `kill-emacs-hook` and every `terra-emacs-autosave-interval` seconds; apply the autosave at start |

STATE is a state plist or a state file name. `terra-emacs-write-state`
and `terra-emacs-read-state` handle the files.

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
                          (env ("CLAUDE_CONFIG_DIR" . "~/.claude"))
                          (terra-key claude "ce20793a-...")))
       (:leaf ("*shell*" (handler . terra-emacs-eat-bookmark-handler)
                         (buffer-name . "*shell*") (cwd . "~/src/")
                         (argv "/bin/zsh")
                         (terra-key eat "*shell*" ("/bin/zsh")))))))))
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
- **Layouts** are split trees, after kiwanami's window-layout recipes:
  `(:split right|below :sizes SHARES :children NODES)` or
  `(:leaf RECORD [:selected t])`.
- **Leaves** are bookmark records. Any mode with bookmark support
  restores for free. terra-emacs adds `buffer-name`, and `terra-key`
  (the leaf's identity, which decides whether a window already shows
  the right thing).

## Plan and apply

A plan is a list of steps such as `(:op create :ws "notes" :id ...)`,
`(:op rename :ws "code" :to "src")`, `(:op move :ws "mail" :to 0)` and
`(:op layout :ws "code" :layout TREE :why differs)`. A layout is rebuilt
only when its shape or a leaf's key differs, or a leaf's process has
died. Rebuilding reuses a live buffer for each leaf, so a process starts
only where one is missing.

## Handlers

| Leaf | Captured | Restored |
|---|---|---|
| files, dired, Info, help, ... | `bookmark-make-record` | `bookmark-handle-bookmark` (a missing file gives a placeholder, never a prompt) |
| eshell | cwd, buffer name | the live eshell of that name, else a new one in cwd |
| eat | cwd, argv | the live buffer running that argv, else argv re-run in cwd. eat has no bookmark support of its own; this adds a `bookmark-make-record-function` |
| vterm | cwd, `vterm-shell` | the same, through `vterm-mode` |
| Claude Code in eat | session id (from `~/.claude/sessions/<pid>.json`), cwd, argv minus `--resume`/`--session-id`/`--continue`, env (`terra-emacs-claude-env-regexp`, never names matching TOKEN, KEY, SECRET or PASSWORD) | argv `--resume ID` in eat, with inherited `CLAUDE*`, `CLAUDECODE`, `AGENT_*`, `AWAD_*`, `LOADOUT_*` and `BD_ACTOR` removed from the child env |
| anything else | the buffer name | that buffer (created empty if gone) |

Claude sessions never get two writers. When the session file shows the
session live and an eat buffer in this Emacs runs it, that buffer is
reused. When it is live anywhere else, `terra-emacs-claude-view-function`
opens a read-only view instead and says so.

Add a handler with `(add-hook 'terra-emacs-leaf-capture-functions FN)`.
FN takes a buffer and returns a record whose `handler` restores it, or
returns nil to pass.

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

- Capture stores each window's leaf record in the `terra-emacs-leaf`
  window parameter, which is listed in `window-persistent-parameters`
  (as activities.el does). It then reads the tree off `window-state-get`
  WRITABLE.
- Apply turns the tree into a window state for `window-state-put`.
- Leaves are `bookmark-make-record` records.

## Prior art

| Tool | Captures | Restores | Declarative file, diff, plan | Terminals with their command | Claude session by id |
|---|---|---|---|---|---|
| desktop.el | buffers, frames (frameset) | replay at start | no | no | no |
| frameset | frames and window states | `frameset-restore` | no | no | no |
| burly | window configs as bookmarks | replay | no | no | no |
| activities.el | per-activity window state + bookmarks | replay, default/last | no | no | no |
| persp-mode, perspective, tabspaces | per-workspace buffers/windows | session file replay | no | no | no |
| easysession, workgroups2 | sessions | replay | no | no | no |
| **terra-emacs** | the declarative set and layouts, from any live Emacs | idempotent converge | yes: diff, plan, dry run, apply | eat, vterm, eshell (cwd and command) | yes, never two writers |

Everything before it is snapshot and replay. Replaying a snapshot over a
live Emacs duplicates what is already there. terra-emacs instead diffs
the desired state against the live one and changes only the difference,
so the same file serves for start-up, a restart and hand-written
layouts.

## Tests

`test/test_terra_emacs.sh [suite...]` byte-compiles every file with
warnings as errors. It then runs each `test/test-*.el` ERT suite in its
own batch Emacs, one at a time. eat and persp-mode come from
`TERRA_EMACS_TEST_PACKAGES` (default `/opt/emacs-test-packages`).
