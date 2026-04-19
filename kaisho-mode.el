;;; kaisho-mode.el --- Emacs integration for Kaisho -*- lexical-binding: t -*-

;; Copyright (C) 2026 Ramon Bartl

;; Author: Ramon Bartl <rb@ridingbytes.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (org "9.5") (websocket "1.12"))
;; Keywords: tools, org, productivity, time-tracking
;; URL: https://github.com/ridingbytes/kaisho-mode
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; kaisho-mode integrates Emacs with the Kaisho productivity app.
;;
;; Kaisho is a local-first productivity platform that manages tasks,
;; customers, contracts and time tracking.  This package is a thin
;; Emacs client that delegates all data operations to the `kai' CLI.
;; No org file parsing is done here.
;;
;; The only required configuration is the path to the `kai' executable:
;;
;;   (use-package kaisho-mode
;;     :straight (:host github :repo "ridingbytes/kaisho-mode")
;;     :config
;;     (setq kaisho-cli-executable "/path/to/.venv/bin/kai")
;;     (setq kaisho-org-dir "~/your/org/dir/")
;;     (kaisho-configure-org)
;;     (kaisho-mode +1))
;;
;; Default keybindings use the C-c k prefix.
;; For Doom Emacs, bind them under SPC n k instead.

;;; Code:

(require 'org)
(require 'json)
(require 'url)


;;; ---------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------

(defgroup kaisho nil
  "Emacs integration for the Kaisho productivity app."
  :group 'org
  :prefix "kaisho-")

(defcustom kaisho-cli-executable "kai"
  "Path or name of the kai CLI executable."
  :type 'string
  :group 'kaisho)

(defcustom kaisho-org-dir (expand-file-name "~/org/")
  "Directory containing all Kaisho org files.
Used for org-mode integration: agenda files, refile targets,
and capture templates.  Must match the org directory configured
in the Kaisho app settings."
  :type 'directory
  :group 'kaisho)

(defcustom kaisho-backend-url "http://localhost:8765"
  "Base URL of the kaisho backend, without trailing slash.
The WebSocket URL is derived by replacing http with ws (or
https with wss).  Adjust this to match the port configured in
your kaisho profile."
  :type 'string
  :group 'kaisho)

(defcustom kaisho-reconnect-delay 5
  "Seconds to wait before reconnecting after a WebSocket disconnect."
  :type 'integer
  :group 'kaisho)

(defcustom kaisho-mode-line-format " [⏱ %d %h:%02m]"
  "Format string for the active-clock mode-line indicator.
%d is replaced with the clock description (falls back to
customer), %h with elapsed hours, %02m with zero-padded elapsed
minutes within the current hour."
  :type 'string
  :group 'kaisho)

(defface kaisho-mode-line-clock
  '((t :foreground "#e5a50a" :weight bold))
  "Face for the kaisho active-clock mode-line indicator."
  :group 'kaisho)


;;; ---------------------------------------------------------------
;;; File accessors (derived from kaisho-org-dir at call time)
;;; ---------------------------------------------------------------

(defun kaisho-todos-file ()
  "Return absolute path to todos.org."
  (expand-file-name "todos.org" kaisho-org-dir))

(defun kaisho-clocks-file ()
  "Return absolute path to clocks.org."
  (expand-file-name "clocks.org" kaisho-org-dir))

(defun kaisho-notes-file ()
  "Return absolute path to notes.org."
  (expand-file-name "notes.org" kaisho-org-dir))

(defun kaisho-archive-file ()
  "Return absolute path to archive.org."
  (expand-file-name "archive.org" kaisho-org-dir))

(defun kaisho-customers-file ()
  "Return absolute path to customers.org."
  (expand-file-name "customers.org" kaisho-org-dir))


;;; ---------------------------------------------------------------
;;; Result cache
;;; ---------------------------------------------------------------

(defcustom kaisho-cache-ttl 60
  "Seconds to cache kai CLI results.
Set to 0 to disable caching."
  :type 'integer
  :group 'kaisho)

(defvar kaisho--cache (make-hash-table :test 'equal)
  "Cache table: key -> (timestamp . data).")

(defun kaisho--cached-call-json (cache-key &rest args)
  "Return cached result for CACHE-KEY, or call kai CLI with ARGS.
Cache entries expire after `kaisho-cache-ttl' seconds."
  (let* ((now   (float-time))
         (entry (gethash cache-key kaisho--cache))
         (ts    (car entry))
         (data  (cdr entry)))
    (if (and entry (< (- now ts) kaisho-cache-ttl))
        data
      (let ((result (apply #'kaisho--call-json-safe args)))
        (puthash cache-key (cons now result) kaisho--cache)
        result))))

(defun kaisho-cache-clear ()
  "Invalidate the kaisho CLI result cache."
  (interactive)
  (clrhash kaisho--cache)
  (message "kaisho: cache cleared"))


;;; ---------------------------------------------------------------
;;; Live clock: WebSocket + REST
;;; ---------------------------------------------------------------

(defvar kaisho--ws nil
  "Active `websocket' object, or nil when disconnected.")

(defvar kaisho--active-clock nil
  "Plist for the running clock as returned by /api/clocks/active,
or nil when no clock is active.")

(defvar kaisho--last-clock nil
  "Plist of the most recently stopped clock.
Saved on stop so the user can resume it on the next toggle.")

(defvar kaisho--mode-line-string ""
  "Mode-line segment updated by `kaisho--update-mode-line'.")

(defvar kaisho--tick-timer nil
  "Repeating timer that refreshes elapsed-time display every 60s.")

(defvar kaisho--mode-line-spec '(:eval kaisho--mode-line-string)
  "Mode-line spec added to `global-mode-string'.")

(defun kaisho--ws-url ()
  "Derive the WebSocket URL from `kaisho-backend-url'."
  (replace-regexp-in-string
   "^https" "wss"
   (replace-regexp-in-string "^http" "ws" kaisho-backend-url)))

(defun kaisho--elapsed-minutes (start-iso)
  "Return elapsed minutes since START-ISO (ISO-8601 string)."
  (let* ((start (date-to-time start-iso))
         (elapsed (float-time (time-subtract (current-time) start))))
    (floor (/ elapsed 60))))

(defun kaisho--update-mode-line ()
  "Recompute `kaisho--mode-line-string' from `kaisho--active-clock'."
  (setq kaisho--mode-line-string
        (if kaisho--active-clock
            (let* ((desc (or (plist-get kaisho--active-clock :description)
                             (plist-get kaisho--active-clock :customer)
                             "?"))
                   (start (plist-get kaisho--active-clock :start))
                   (total (kaisho--elapsed-minutes start))
                   (h (/ total 60))
                   (m (% total 60)))
              (propertize
               (format-spec kaisho-mode-line-format
                            `((?d . ,desc) (?h . ,h) (?m . ,m)))
               'face 'kaisho-mode-line-clock))
          ""))
  (force-mode-line-update t))

(defun kaisho--set-clock (data)
  "Record DATA as the active clock and start the tick timer."
  (setq kaisho--active-clock data)
  (kaisho--update-mode-line)
  (unless kaisho--tick-timer
    (setq kaisho--tick-timer
          (run-with-timer 60 60 #'kaisho--update-mode-line))))

(defun kaisho--clear-clock ()
  "Clear the active clock and stop the tick timer."
  (setq kaisho--active-clock nil)
  (when kaisho--tick-timer
    (cancel-timer kaisho--tick-timer)
    (setq kaisho--tick-timer nil))
  (kaisho--update-mode-line))

(defun kaisho--fetch-active ()
  "Fetch /api/clocks/active via REST and update clock state."
  (url-retrieve
   (concat kaisho-backend-url "/api/clocks/active")
   (lambda (status)
     (if (plist-get status :error)
         (kaisho--clear-clock)
       (goto-char (point-min))
       (when (re-search-forward "^$" nil t)
         (let* ((json-object-type 'plist)
                (json-false nil)
                (data (ignore-errors (json-read))))
           (if (or (null data) (null (plist-get data :active)))
               (kaisho--clear-clock)
             (kaisho--set-clock data))))))
   nil
   :silent))

(defun kaisho--on-message (_ws frame)
  "Handle an incoming WebSocket FRAME."
  (let* ((json-object-type 'plist)
         (json-false nil)
         (payload (ignore-errors
                    (json-read-from-string
                     (websocket-frame-text frame))))
         (resource (and payload (plist-get payload :resource))))
    (when (equal resource "clocks")
      (kaisho--fetch-active))))

(defun kaisho--on-close (_ws)
  "Handle WebSocket disconnect; schedule a reconnect."
  (setq kaisho--ws nil)
  (when kaisho-mode
    (run-with-timer kaisho-reconnect-delay nil #'kaisho--ws-connect)))

(defun kaisho--ws-connect ()
  "Open (or reopen) the WebSocket connection to kaisho."
  (if (not (require 'websocket nil t))
      (message (concat "kaisho: websocket.el not found -- "
                       "live clock updates disabled. "
                       "Add (package! websocket) to packages.el "
                       "and run doom sync."))
    (when (and kaisho--ws (websocket-openp kaisho--ws))
      (websocket-close kaisho--ws))
    (condition-case err
        (progn
          (setq kaisho--ws
                (websocket-open
                 (concat (kaisho--ws-url) "/ws")
                 :on-message #'kaisho--on-message
                 :on-close   #'kaisho--on-close
                 :on-error   (lambda (_ws _type e)
                               (message "kaisho: WS error: %s" e))))
          (kaisho--fetch-active))
      (error
       (message "kaisho: cannot connect to %s (%s); retry in %ds"
                kaisho-backend-url err kaisho-reconnect-delay)
       (run-with-timer kaisho-reconnect-delay nil
                       #'kaisho--ws-connect)))))

(defun kaisho--ws-disconnect ()
  "Close the WebSocket connection and clear clock state."
  (when kaisho--tick-timer
    (cancel-timer kaisho--tick-timer)
    (setq kaisho--tick-timer nil))
  (when (and kaisho--ws (websocket-openp kaisho--ws))
    (websocket-close kaisho--ws))
  (setq kaisho--ws nil)
  (kaisho--clear-clock))

;;;###autoload
(defun kaisho-reconnect ()
  "Manually reconnect to the kaisho backend WebSocket."
  (interactive)
  (kaisho--ws-disconnect)
  (kaisho--ws-connect))


;;; ---------------------------------------------------------------
;;; CLI runner
;;; ---------------------------------------------------------------

(defun kaisho--call (&rest args)
  "Run kai CLI with ARGS and return stdout as a string.
Signals an error when the process exits non-zero."
  (with-temp-buffer
    (let ((exit-code (apply #'call-process
                            kaisho-cli-executable nil t nil args)))
      (unless (zerop exit-code)
        (error "kai %s failed: %s"
               (mapconcat #'identity args " ")
               (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun kaisho--call-json (&rest args)
  "Run kai CLI with ARGS, parse stdout as JSON and return it.
JSON arrays become lists, objects become alists."
  (let* ((json-array-type 'list)
         (json-object-type 'alist)
         (json-false nil)
         (output (apply #'kaisho--call args)))
    (json-read-from-string output)))

(defun kaisho--call-json-safe (&rest args)
  "Like `kaisho--call-json' but return nil on any error."
  (condition-case err
      (apply #'kaisho--call-json args)
    (error
     (message "kaisho: %s" (error-message-string err))
     nil)))


;;; ---------------------------------------------------------------
;;; Data access via CLI
;;; ---------------------------------------------------------------

(defun kaisho-customers ()
  "Return list of active customer name strings via kai CLI."
  (let ((data (kaisho--cached-call-json
               "customers" "customer" "list" "--json")))
    (mapcar (lambda (c) (alist-get 'name c)) data)))

(defun kaisho-customer-contracts (customer)
  "Return available contract names for CUSTOMER via kai CLI.
Excludes contracts with billable=false or invoiced=true."
  (let ((data (kaisho--cached-call-json
               (concat "contracts/" customer)
               "contract" "list" customer "--json")))
    (mapcar
     (lambda (c) (alist-get 'name c))
     (seq-filter
      (lambda (c)
        (and (not (eq (alist-get 'billable c) nil))
             (not (eq (alist-get 'invoiced c) t))))
      data))))

(defun kaisho-clock-tasks (customer)
  "Return recent task descriptions for CUSTOMER via kai CLI."
  (let ((data (kaisho--cached-call-json
               (concat "clock-tasks/" customer)
               "clock" "list" "--customer" customer "--json")))
    (delete-dups
     (delq nil
           (mapcar (lambda (e) (alist-get 'description e))
                   data)))))

(defun kaisho--clock-active-p ()
  "Return non-nil when a clock is active.
Uses the cached WebSocket state when connected; falls back to the
kai CLI otherwise."
  (if kaisho--ws
      (not (null kaisho--active-clock))
    (let ((data (kaisho--call-json-safe "clock" "status" "--json")))
      (and data (not (eq data :json-null))))))


;;; ---------------------------------------------------------------
;;; Clock operations via CLI
;;; ---------------------------------------------------------------

(defun kaisho--fmt-mins (minutes)
  "Format MINUTES (integer) as a string like 2h05m."
  (format "%dh%02dm" (/ minutes 60) (% minutes 60)))

(defun kaisho-clock-toggle ()
  "Toggle the clock on a Kaisho task via the kai CLI.

When a clock is active: run `kai clock stop'.
When no clock is active: prompt for customer, optional contract
and task description, then run `kai clock start'."
  (interactive)
  (if (kaisho--clock-active-p)
      (progn
        (kaisho--call "clock" "stop")
        (setq kaisho--last-clock kaisho--active-clock)
        (kaisho--clear-clock)
        (message "Clock stopped"))
    (kaisho--clock-start-new)))

(defun kaisho--clock-resume ()
  "Resume `kaisho--last-clock' without prompting.
Returns non-nil on success."
  (let* ((customer (or (plist-get kaisho--last-clock :customer) ""))
         (desc     (or (plist-get kaisho--last-clock :description) ""))
         (contract (plist-get kaisho--last-clock :contract))
         (result   (kaisho--call-json-safe
                    "clock" "start" customer desc "--json")))
    (when (and contract result)
      (let ((start-iso (alist-get 'start result)))
        (when start-iso
          (kaisho--call-json-safe
           "clock" "update" start-iso "--contract" contract))))
    (when result
      (kaisho--set-clock
       (list :customer customer
             :description desc
             :start (alist-get 'start result))))
    (when result
      (message "Clock resumed: [%s]%s %s"
               customer
               (if contract (format " (%s)" contract) "")
               desc))
    result))

(defun kaisho--clock-start-new ()
  "Prompt for customer, contract and task, then call kai clock start."
  (unless (and kaisho--last-clock
               (y-or-n-p
                (format "Resume [%s - %s]? "
                        (or (plist-get kaisho--last-clock :customer) "")
                        (or (plist-get kaisho--last-clock :description) "")))
               (kaisho--clock-resume))
  (let* ((customer (completing-read
                    "Customer: " (kaisho-customers) nil nil))
         (customer (if (string-empty-p customer) "Misc" customer))
         (contracts (kaisho-customer-contracts customer))
         (contract
          (when contracts
            (let ((choice (completing-read
                           (format "[%s] Contract: " customer)
                           (cons "- none -" contracts) nil t)))
              (unless (string= choice "- none -") choice))))
         (task (completing-read
                (format "[%s] Task: " customer)
                (kaisho-clock-tasks customer) nil nil))
         (result (kaisho--call-json-safe
                  "clock" "start" customer task "--json")))
    (when result
      (when contract
        (let ((start-iso (alist-get 'start result)))
          (when start-iso
            (kaisho--call-json-safe
             "clock" "update" start-iso
             "--contract" contract))))
      (kaisho--set-clock
       (list :customer customer
             :description task
             :start (alist-get 'start result)))
      (message "Clock started: [%s]%s %s"
               customer
               (if contract
                   (format " (%s)" contract) "")
               task)))))

(defun kaisho-clock-today-summary ()
  "Show today's clocked time per customer in the minibuffer."
  (interactive)
  (let* ((today (format-time-string "%Y-%m-%d"))
         (entries (kaisho--call-json-safe
                   "clock" "list"
                   "--from" today "--to" today "--json"))
         (totals (make-hash-table :test 'equal)))
    (dolist (e (or entries '()))
      (let* ((cust (or (alist-get 'customer e) "?"))
             (mins (or (alist-get 'duration_minutes e) 0)))
        (puthash cust (+ (gethash cust totals 0) mins) totals)))
    (if (hash-table-empty-p totals)
        (message "No time clocked today")
      (let (pairs (total-mins 0))
        (maphash (lambda (k v)
                   (push (cons k v) pairs)
                   (setq total-mins (+ total-mins v)))
                 totals)
        (message "Today: %s  |  %s"
                 (kaisho--fmt-mins total-mins)
                 (mapconcat
                  (lambda (p)
                    (format "%s %s" (car p)
                            (kaisho--fmt-mins (cdr p))))
                  (nreverse pairs) "  "))))))

(defun kaisho-clock-goto ()
  "Open clocks.org and move to the most recent open clock entry."
  (interactive)
  (find-file (kaisho-clocks-file))
  (goto-char (point-min))
  (if (re-search-forward "CLOCK: \\[[^]]+\\]$" nil t)
      (beginning-of-line)
    (message "No open clock entry found")))

(defun kaisho-clock-report ()
  "Open clocks.org and update or insert a weekly clock table."
  (interactive)
  (find-file (kaisho-clocks-file))
  (revert-buffer t t t)
  (goto-char (point-min))
  (if (re-search-forward "^#\\+BEGIN: clocktable" nil t)
      (progn
        (beginning-of-line)
        (org-ctrl-c-ctrl-c)
        (message "Clock table updated"))
    (when (re-search-forward "^\\*" nil t)
      (beginning-of-line)
      (insert "#+BEGIN: clocktable "
              ":scope file :maxlevel 1 "
              ":block thisweek :step day\n"
              "#+END:\n\n")
      (forward-line -2)
      (org-ctrl-c-ctrl-c)
      (message "Clock table inserted"))))


;;; ---------------------------------------------------------------
;;; Manual backdated clock entry via CLI
;;; ---------------------------------------------------------------

(defun kaisho-insert-clock-entry ()
  "Insert a backdated clock entry via kai clock book + update.
Prompts for customer, contract, task, date, start and end time."
  (interactive)
  (let* ((customer (completing-read
                    "Customer: " (kaisho-customers) nil nil))
         (customer (if (string-empty-p customer) "Misc" customer))
         (contracts (kaisho-customer-contracts customer))
         (contract
          (when contracts
            (let ((choice (completing-read
                           (format "[%s] Contract: " customer)
                           (cons "- none -" contracts) nil t)))
              (unless (string= choice "- none -") choice))))
         (task (completing-read
                (format "[%s] Task: " customer)
                (kaisho-clock-tasks customer) nil nil))
         (date-str (org-read-date nil nil nil "Date: "))
         (start-str (read-string "Start (HH:MM): "))
         (end-str   (read-string "End   (HH:MM): "))
         (dur-mins  (- (kaisho--hhmm-to-mins end-str)
                       (kaisho--hhmm-to-mins start-str)))
         (dur-str   (format "%dmin" dur-mins))
         (result    (kaisho--call-json-safe
                     "clock" "book" dur-str customer task "--json")))
    (when result
      (let* ((start-iso (alist-get 'start result))
             (hours     (/ dur-mins 60.0))
             (update-args
              (append (list "clock" "update" start-iso
                            "--date" date-str
                            "--hours" (number-to-string hours))
                      (when contract
                        (list "--contract" contract)))))
        (apply #'kaisho--call update-args))
      (message "Booked %s for [%s]%s: %s"
               dur-str customer
               (if contract (format " (%s)" contract) "")
               task))))

(defun kaisho--hhmm-to-mins (hhmm)
  "Convert HH:MM string to total minutes."
  (+ (* 60 (string-to-number (substring hhmm 0 2)))
     (string-to-number (substring hhmm 3 5))))


;;; ---------------------------------------------------------------
;;; Project / capture helpers via CLI
;;; ---------------------------------------------------------------

(defun kaisho-capture-select-project ()
  "Prompt for a customer name; return it as a [Customer] tag string.
Reads customer list from the kai CLI.  Intended for use inside
org capture templates."
  (let* ((customers (kaisho-customers))
         (raw (completing-read "Project: " customers nil nil)))
    (if (string-match-p "^\\[.*\\]$" raw)
        raw
      (format "[%s]" raw))))

(defun kaisho-change-project-tag ()
  "Replace the [Customer] prefix on the org heading at point.
Customer list is read from the kai CLI."
  (interactive)
  (save-excursion
    (org-back-to-heading t)
    (let ((new   (kaisho-capture-select-project))
          (bound (line-end-position)))
      (if (re-search-forward "\\(\\[[^]]+\\]\\)" bound t)
          (replace-match new)
        (when (re-search-forward
               "^\\*+\\s-+\\(?:\\w+-?\\w*\\)\\s-+"
               bound t)
          (insert (concat new " ")))))))


;;; ---------------------------------------------------------------
;;; File navigation
;;; ---------------------------------------------------------------

(defun kaisho-open-todos ()
  "Open todos.org."
  (interactive)
  (find-file (kaisho-todos-file)))

(defun kaisho-open-clocks ()
  "Open clocks.org."
  (interactive)
  (find-file (kaisho-clocks-file)))

(defun kaisho-open-notes ()
  "Open notes.org."
  (interactive)
  (find-file (kaisho-notes-file)))


;;; ---------------------------------------------------------------
;;; kai CLI runner (interactive)
;;; ---------------------------------------------------------------

(defun kaisho-debug ()
  "Show diagnostic output to help troubleshoot kaisho-mode.
Runs `kai customer list --json' and displays the raw result."
  (interactive)
  (let ((buf (get-buffer-create "*kaisho-debug*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "kaisho-cli-executable: %s\n" kaisho-cli-executable))
      (insert (format "kaisho-org-dir: %s\n\n" kaisho-org-dir))
      (insert "--- kai customer list --json ---\n")
      (let* ((exit-code (call-process kaisho-cli-executable nil t nil
                                      "customer" "list" "--json")))
        (insert (format "\n--- exit code: %d ---\n" exit-code))))
    (pop-to-buffer buf)))

(defun kaisho-run-command (args)
  "Run the kai CLI with ARGS (a string) in a compilation buffer."
  (compile (concat kaisho-cli-executable " " args)))

(defun kaisho-run-command-interactive ()
  "Prompt for kai CLI arguments and run the command."
  (interactive)
  (kaisho-run-command (read-string "kai args: ")))


;;; ---------------------------------------------------------------
;;; Org-mode configuration helper
;;; ---------------------------------------------------------------

(defun kaisho-configure-org ()
  "Configure org-mode to use Kaisho files.

Call this after setting `kaisho-org-dir'.  Sets org-directory,
default-notes-file, agenda files, refile targets and archive
location.  Does not touch TODO keywords, capture templates or
agenda views -- configure those in your init file."
  (setq org-directory          kaisho-org-dir
        org-default-notes-file (kaisho-notes-file))
  (setq org-agenda-files
        (list (kaisho-todos-file) (kaisho-clocks-file))))


;;; ---------------------------------------------------------------
;;; Minor mode
;;; ---------------------------------------------------------------

(defvar kaisho-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Clock
    (define-key map (kbd "C-c k t") #'kaisho-clock-toggle)
    (define-key map (kbd "C-c k s") #'kaisho-clock-today-summary)
    (define-key map (kbd "C-c k g") #'kaisho-clock-goto)
    (define-key map (kbd "C-c k i") #'kaisho-insert-clock-entry)
    (define-key map (kbd "C-c k r") #'kaisho-clock-report)
    ;; Files
    (define-key map (kbd "C-c k f t") #'kaisho-open-todos)
    (define-key map (kbd "C-c k f c") #'kaisho-open-clocks)
    (define-key map (kbd "C-c k f n") #'kaisho-open-notes)
    ;; CLI
    (define-key map (kbd "C-c k !") #'kaisho-run-command-interactive)
    (define-key map (kbd "C-c k X") #'kaisho-cache-clear)
    ;; Backend
    (define-key map (kbd "C-c k R") #'kaisho-reconnect)
    map)
  "Keymap for `kaisho-mode'.

Default bindings use C-c k as the prefix:
  t   kaisho-clock-toggle
  s   kaisho-clock-today-summary
  g   kaisho-clock-goto
  i   kaisho-insert-clock-entry
  r   kaisho-clock-report
  f t kaisho-open-todos
  f c kaisho-open-clocks
  f n kaisho-open-notes
  !   kaisho-run-command-interactive
  X   kaisho-cache-clear
  R   kaisho-reconnect")

;;;###autoload
(define-minor-mode kaisho-mode
  "Minor mode for Kaisho productivity integration.

Provides clock management, task navigation and kai CLI access
for the Kaisho local-first productivity app.  All data operations
are delegated to the `kai' CLI; no org files are parsed directly.

When enabled, connects to the kaisho backend at
`kaisho-backend-url' via WebSocket and keeps an active-clock
indicator in the mode line up to date in real time.  Use
`kaisho-reconnect' (C-c k R) to reconnect manually.

\\{kaisho-mode-map}"
  :init-value nil
  :lighter " Kaisho"
  :keymap kaisho-mode-map
  :global t
  :group 'kaisho
  (if kaisho-mode
      (progn
        (add-to-list 'global-mode-string kaisho--mode-line-spec t)
        (kaisho--ws-connect))
    (kaisho--ws-disconnect)
    (setq global-mode-string
          (delete kaisho--mode-line-spec global-mode-string))))

(provide 'kaisho-mode)

;;; kaisho-mode.el ends here
