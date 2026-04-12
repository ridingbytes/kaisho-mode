# kaisho-mode

Emacs integration for the [Kaisho](https://github.com/ridingbytes/kaisho)
local-first productivity platform.

Kaisho manages tasks, customers, contracts and time tracking through
org-mode files.  This package makes Emacs a first-class client for those
files, using `org-clock` for time tracking rather than reimplementing it.

## Features

- Clock in and out on customer/contract tasks via `org-clock`
- Customer and contract completion pulled from `customers.org`
- Manual backdated clock entry insertion
- Today's clock summary in the minibuffer
- Weekly clock report table (inserted into `clocks.org`)
- Navigate to the current or last clocked task
- Open Kaisho org files directly
- Run `kai` CLI commands from Emacs

## Requirements

- Emacs 27.1 or later
- Org-mode 9.5 or later
- A running Kaisho installation (for the `kai` CLI commands)

## Installation

### straight.el

```elisp
(use-package kaisho-mode
  :straight (:host github :repo "ridingbytes/kaisho-mode")
  :config
  (setq kaisho-org-dir "~/ownCloud/cowork/org/")
  (kaisho-configure-org)
  (kaisho-mode +1))
```

### elpaca

```elisp
(use-package kaisho-mode
  :elpaca (:host github :repo "ridingbytes/kaisho-mode")
  :config
  (setq kaisho-org-dir "~/ownCloud/cowork/org/")
  (kaisho-configure-org)
  (kaisho-mode +1))
```

### Manual

Clone this repository and add the directory to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/kaisho-mode")
(require 'kaisho-mode)
```

## Configuration

### Directory

Set `kaisho-org-dir` to the directory that contains your Kaisho org files.
This must match the org directory configured in the Kaisho app settings.

```elisp
(setq kaisho-org-dir "~/ownCloud/cowork/org/")
```

The package derives all file paths from this variable at call time, so
changing it takes effect without restarting Emacs.

### Org-mode setup

`kaisho-configure-org` sets the essential org-mode variables to point at
Kaisho files.  Call it after setting `kaisho-org-dir`:

```elisp
(kaisho-configure-org)
```

This configures:
- `org-directory` and `org-default-notes-file`
- `org-agenda-files` (todos.org and clocks.org)
- Clock persistence, `org-clock-into-drawer`, `org-clock-out-when-done`

TODO keywords, capture templates and agenda views are intentionally left
to your personal config.

### CLI executable

If `kai` is not on your `exec-path`, set the full path.  When running
Kaisho from a local checkout with a virtualenv, point directly to the
executable inside `.venv`:

```elisp
(setq kaisho-cli-executable
      (expand-file-name "~/develop/kaisho/.venv/bin/kai"))
```

## Default keybindings

When `kaisho-mode` is enabled, the following bindings are active globally
under the `C-c k` prefix:

| Key         | Command                          | Description                    |
|-------------|----------------------------------|--------------------------------|
| `C-c k t`   | `kaisho-clock-toggle`            | Start or stop the clock        |
| `C-c k s`   | `kaisho-clock-today-summary`     | Show today's clocked time      |
| `C-c k g`   | `kaisho-clock-goto`              | Jump to current/last clock     |
| `C-c k i`   | `kaisho-insert-clock-entry`      | Insert a backdated clock entry |
| `C-c k r`   | `kaisho-clock-report`            | Insert/update clock table      |
| `C-c k x`   | `org-clock-cancel`               | Cancel the running clock       |
| `C-c k f t` | `kaisho-open-todos`              | Open todos.org                 |
| `C-c k f c` | `kaisho-open-clocks`             | Open clocks.org                |
| `C-c k f n` | `kaisho-open-notes`              | Open notes.org                 |
| `C-c k !`   | `kaisho-run-command-interactive` | Run a kai CLI command          |

## Doom Emacs

With Doom, bind commands under a `SPC n k` prefix instead:

```elisp
(use-package! kaisho-mode
  :straight (:host github :repo "ridingbytes/kaisho-mode")
  :config
  (setq kaisho-org-dir "~/ownCloud/cowork/org/")
  (kaisho-configure-org)
  (kaisho-mode +1))

(map! :leader
      (:prefix ("n k" . "kaisho")
       ;; Files
       :desc "TODOs"          "t" #'kaisho-open-todos
       :desc "Clocks"         "c" #'kaisho-open-clocks
       :desc "Notes"          "n" #'kaisho-open-notes
       ;; Clock
       :desc "Clock toggle"   "k" #'kaisho-clock-toggle
       :desc "Clock summary"  "s" #'kaisho-clock-today-summary
       :desc "Clock goto"     "g" #'kaisho-clock-goto
       :desc "Clock insert"   "i" #'kaisho-insert-clock-entry
       :desc "Clock report"   "r" #'kaisho-clock-report
       :desc "Clock cancel"   "x" #'org-clock-cancel
       ;; CLI
       :desc "Run kai command" "!" #'kaisho-run-command-interactive
       :desc "kai serve"       "S" #'kaisho-serve))
```

## Org file format

Kaisho organises clock entries in a flat heading structure:

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
    :BOOKABLE: true
    :END:
*** CONTRACT Internal
    :PROPERTIES:
    :BOOKABLE: false
    :END:
```

Contracts with `:BOOKABLE: false` are excluded from completion.

## License

GPL-3.0-or-later
