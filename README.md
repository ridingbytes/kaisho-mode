# kaisho-mode

Emacs integration for the [Kaisho](https://github.com/ridingbytes/kaisho)
local-first productivity platform.

This package is a thin Emacs client that delegates all data operations to
the `kai` CLI.  No org files are parsed directly.

## Features

- Clock in and out on customer/contract tasks via `kai clock start/stop`
- Customer and contract completion via `kai customer list` / `kai contract list`
- Recent task descriptions for completion via `kai clock list`
- Manual backdated clock entry via `kai clock book` + `kai clock update`
- Today's clock summary via `kai clock list`
- Weekly clock report table (org clocktable over clocks.org)
- Navigate to the clocks file
- Open Kaisho org files for agenda and refile
- Run any `kai` command from the minibuffer

## Requirements

- Emacs 27.1 or later
- Org-mode 9.5 or later
- The `kai` CLI (from a Kaisho installation)

## Installation

### straight.el

```elisp
(use-package kaisho-mode
  :straight (:host github :repo "ridingbytes/kaisho-mode")
  :config
  (setq kaisho-cli-executable
        (expand-file-name "~/develop/kaisho/.venv/bin/kai"))
  (setq kaisho-org-dir "~/ownCloud/cowork/org/")
  (kaisho-configure-org)
  (kaisho-mode +1))
```

### elpaca

```elisp
(use-package kaisho-mode
  :elpaca (:host github :repo "ridingbytes/kaisho-mode")
  :config
  (setq kaisho-cli-executable
        (expand-file-name "~/develop/kaisho/.venv/bin/kai"))
  (setq kaisho-org-dir "~/ownCloud/cowork/org/")
  (kaisho-configure-org)
  (kaisho-mode +1))
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/kaisho-mode")
(require 'kaisho-mode)
```

## Configuration

### CLI executable

Set `kaisho-cli-executable` to the full path of the `kai` binary.  When
running Kaisho from a virtualenv, point directly to the venv executable:

```elisp
(setq kaisho-cli-executable
      (expand-file-name "~/develop/kaisho/.venv/bin/kai"))
```

Or use a pyenv shim:

```elisp
(setq kaisho-cli-executable
      (expand-file-name "~/.pyenv/shims/kai"))
```

### Org directory

Set `kaisho-org-dir` to the directory containing your Kaisho org files.
Used for org-mode integration (agenda files, refile targets, capture
templates).  Must match the org directory configured in the Kaisho app.

```elisp
(setq kaisho-org-dir "~/ownCloud/cowork/org/")
```

### Org-mode setup

`kaisho-configure-org` sets `org-directory`, `org-default-notes-file`
and `org-agenda-files`.  Call it after setting `kaisho-org-dir`:

```elisp
(kaisho-configure-org)
```

TODO keywords, capture templates, refile targets and agenda views are
intentionally left to your personal config.

## Default keybindings

When `kaisho-mode` is enabled, the following bindings are active globally
under the `C-c k` prefix:

| Key         | Command                          | Description                    |
|-------------|----------------------------------|--------------------------------|
| `C-c k t`   | `kaisho-clock-toggle`            | Start or stop the clock        |
| `C-c k s`   | `kaisho-clock-today-summary`     | Show today's clocked time      |
| `C-c k g`   | `kaisho-clock-goto`              | Open clocks.org, find open clock |
| `C-c k i`   | `kaisho-insert-clock-entry`      | Insert a backdated clock entry |
| `C-c k r`   | `kaisho-clock-report`            | Insert/update clock table      |
| `C-c k f t` | `kaisho-open-todos`              | Open todos.org                 |
| `C-c k f c` | `kaisho-open-clocks`             | Open clocks.org                |
| `C-c k f n` | `kaisho-open-notes`              | Open notes.org                 |
| `C-c k !`   | `kaisho-run-command-interactive` | Run a kai CLI command          |

## Doom Emacs

Use `load` instead of `use-package!` so that `SPC h r r` picks up
changes to the package immediately without a full Emacs restart:

```elisp
;; Always reload from disk on config reload (SPC h r r).
;; use-package! would skip re-evaluation once the feature is loaded.
(load (expand-file-name "~/develop/kaisho-mode/kaisho-mode.el") nil t)
(setq kaisho-org-dir
      (expand-file-name "~/ownCloud/cowork/org/"))
(setq kaisho-cli-executable
      (expand-file-name "~/.pyenv/versions/3.12.12/bin/kai"))
(kaisho-configure-org)
(kaisho-mode +1)

;; SPC n k -- Kaisho workflow
(map! :leader
      (:prefix ("n k" . "kaisho")
       ;; Files
       :desc "TODOs"           "t" #'kaisho-open-todos
       :desc "Clocks"          "c" #'kaisho-open-clocks
       :desc "Notes"           "n" #'kaisho-open-notes
       ;; Clock
       :desc "Clock toggle"    "k" #'kaisho-clock-toggle
       :desc "Clock summary"   "s" #'kaisho-clock-today-summary
       :desc "Clock goto"      "g" #'kaisho-clock-goto
       :desc "Clock insert"    "i" #'kaisho-insert-clock-entry
       :desc "Clock report"    "r" #'kaisho-clock-report
       ;; CLI
       :desc "Run kai command" "!" #'kaisho-run-command-interactive))

;; Optional: accessible from any buffer
(map! :g "<f5>" #'kaisho-clock-toggle)
```

### pyenv note

If `kai` is installed under a specific pyenv Python version, point
`kaisho-cli-executable` at the direct binary rather than the pyenv
shim.  Emacs launched as a GUI app does not run through the login
shell, so pyenv shims cannot resolve which Python to use:

```elisp
;; Wrong: shim fails without shell environment
;; (setq kaisho-cli-executable "~/.pyenv/shims/kai")

;; Correct: direct path to the Python version that has kai installed
(setq kaisho-cli-executable
      (expand-file-name "~/.pyenv/versions/3.12.12/bin/kai"))
```

## Org file format

Kaisho organises clock entries in a flat heading structure written by
the kai backend:

```org
* [CUSTOMER]: task description
  :PROPERTIES:
  :CONTRACT: contract name
  :END:
  :LOGBOOK:
  CLOCK: [2024-05-01 Wed 09:00]--[2024-05-01 Wed 11:30] =>  2:30
  :END:
```

Customer headings in `customers.org` follow this structure:

```org
** Customer Name
*** CONTRACT Contract A
    :PROPERTIES:
    :END:
*** CONTRACT Internal
    :PROPERTIES:
    :BILLABLE: false
    :END:
*** CONTRACT Finished Work
    :PROPERTIES:
    :INVOICED: true
    :END:
```

Contracts with `:BILLABLE: false` or `:INVOICED: true` are excluded
from completion in `kaisho-clock-toggle` and `kaisho-insert-clock-entry`.

## License

GPL-3.0-or-later
