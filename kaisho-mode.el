;;; kaisho-mode.el --- Emacs integration for Kaisho -*- lexical-binding: t -*-

;; Copyright (C) 2026 Ramon Bartl

;; Author: Ramon Bartl <rb@ridingbytes.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1") (org "9.5"))
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
  "Return non-nil when a clock is active, querying the kai CLI."
  (let ((data (kaisho--call-json-safe "clock" "status" "--json")))
    (eq (alist-get 'active data) t)))


;;; ---------------------------------------------------------------
;;; Clock operations via CLI
;;; ---------------------------------------------------------------

(defun kaisho--fmt-h (hours)
  "Format HOURS (float) as a human-readable string like 2h05m."
  (let* ((total-mins (round (* hours 60)))
         (h (/ total-mins 60))
         (m (% total-mins 60)))
    (format "%dh%02dm" h m)))

(defun kaisho-clock-toggle ()
  "Toggle the clock on a Kaisho task via the kai CLI.

When a clock is active: run `kai clock stop'.
When no clock is active: prompt for customer, optional contract
and task description, then run `kai clock start'."
  (interactive)
  (if (kaisho--clock-active-p)
      (progn
        (kaisho--call "clock" "stop")
        (message "Clock stopped"))
    (kaisho--clock-start-new)))

(defun kaisho--clock-start-new ()
  "Prompt for customer, contract and task, then call kai clock start."
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
    (when (and contract result)
      (let ((start-iso (alist-get 'started_at result)))
        (when start-iso
          (kaisho--call-json-safe
           "clock" "update" start-iso "--contract" contract))))
    (message "Clock started: [%s]%s %s"
             customer
             (if contract (format " (%s)" contract) "")
             task)))

(defun kaisho-clock-today-summary ()
  "Show today's clocked time per customer in the minibuffer."
  (interactive)
  (let* ((today (format-time-string "%Y-%m-%d"))
         (entries (kaisho--call-json-safe
                   "clock" "list"
                   "--from" today "--to" today "--json"))
         (totals (make-hash-table :test 'equal))
         (total-h 0.0))
    (dolist (e (or entries '()))
      (let* ((cust (or (alist-get 'customer e) "?"))
             (h (or (alist-get 'hours e) 0.0)))
        (puthash cust (+ (gethash cust totals 0.0) h) totals)))
    (if (hash-table-empty-p totals)
        (message "No time clocked today")
      (maphash (lambda (_ h) (setq total-h (+ total-h h))) totals)
      (let (pairs)
        (maphash (lambda (k v) (push (cons k v) pairs)) totals)
        (message "Today: %s  |  %s"
                 (kaisho--fmt-h total-h)
                 (mapconcat
                  (lambda (p)
                    (format "%s %s" (car p)
                            (kaisho--fmt-h (cdr p))))
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
      (let* ((start-iso (alist-get 'started_at result))
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
  X   kaisho-cache-clear")

;;;###autoload
(define-minor-mode kaisho-mode
  "Minor mode for Kaisho productivity integration.

Provides clock management, task navigation and kai CLI access
for the Kaisho local-first productivity app.  All data operations
are delegated to the `kai' CLI; no org files are parsed directly.

\\{kaisho-mode-map}"
  :init-value nil
  :lighter " Kaisho"
  :keymap kaisho-mode-map
  :global t
  :group 'kaisho)

(provide 'kaisho-mode)

;;; kaisho-mode.el ends here
