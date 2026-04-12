;;; kaisho-mode.el --- Emacs integration for Kaisho -*- lexical-binding: t -*-

;; Copyright (C) 2024 Ramon Bartl

;; Author: Ramon Bartl <rb@ridingbytes.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (org "9.5"))
;; Keywords: tools, org, productivity, time-tracking
;; URL: https://github.com/ridingbytes/kaisho-mode
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; kaisho-mode integrates Emacs with the Kaisho productivity app.
;;
;; Kaisho is a local-first productivity platform that manages tasks,
;; customers, contracts and time tracking via org-mode files.  This
;; package makes Emacs a first-class client for those files, using
;; org-clock for time tracking rather than reimplementing it.
;;
;; Features:
;;   - Clock in/out on customer+contract tasks using org-clock
;;   - Manual backdated clock entry insertion
;;   - Clock summary for today, clock report table
;;   - Customer and contract completion from customers.org
;;   - Capture templates wired to Kaisho org files
;;   - Run kai CLI commands from within Emacs
;;
;; Quickstart:
;;
;;   (use-package kaisho-mode
;;     :load-path "/path/to/kaisho-mode"
;;     :config
;;     (setq kaisho-org-dir "~/your/org/dir/")
;;     (kaisho-configure-org)
;;     (kaisho-mode +1))
;;
;; Default keybindings use the C-c k prefix.
;; For Doom Emacs, bind them under SPC n k instead.

;;; Code:

(require 'org)
(require 'org-clock)


;;; ---------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------

(defgroup kaisho nil
  "Emacs integration for the Kaisho productivity app."
  :group 'org
  :prefix "kaisho-")

(defcustom kaisho-org-dir (expand-file-name "~/org/")
  "Directory containing all Kaisho org files.
This must match the org directory configured in the Kaisho app."
  :type 'directory
  :group 'kaisho)

(defcustom kaisho-cli-executable "kai"
  "Path or name of the kai CLI executable."
  :type 'string
  :group 'kaisho)

(defcustom kaisho-clock-buffer-name "*Kaisho Clock*"
  "Buffer name used for kai CLI output."
  :type 'string
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
;;; Data access: customers, contracts, tasks
;;; ---------------------------------------------------------------

(defun kaisho-customers ()
  "Return unique customer names from customers.org and clocks.org."
  (let (customers)
    (when (file-exists-p (kaisho-customers-file))
      (with-temp-buffer
        (insert-file-contents (kaisho-customers-file))
        (while (re-search-forward "^\\*\\* \\(.+\\)$" nil t)
          (push (string-trim (match-string-no-properties 1))
                customers))))
    (when (file-exists-p (kaisho-clocks-file))
      (with-temp-buffer
        (insert-file-contents (kaisho-clocks-file))
        (while (re-search-forward
                "^\\* \\[\\([^]]+\\)\\]:" nil t)
          (push (match-string-no-properties 1) customers))))
    (delete-dups (nreverse customers))))

(defun kaisho-customer-contracts (customer)
  "Return bookable contract names for CUSTOMER from customers.org.
Contracts with a :BOOKABLE: false property are excluded."
  (when (file-exists-p (kaisho-customers-file))
    (with-temp-buffer
      (insert-file-contents (kaisho-customers-file))
      (let (contracts
            (cust-re (concat "^\\*\\* "
                             (regexp-quote customer)
                             "\\s-*$")))
        (when (re-search-forward cust-re nil t)
          (let ((section-end
                 (save-excursion
                   (if (re-search-forward
                        "^\\*\\* " nil t)
                       (point)
                     (point-max)))))
            (while (re-search-forward
                    "^\\*\\*\\* CONTRACT \\(.+\\)$"
                    section-end t)
              (let* ((name (string-trim
                            (match-string-no-properties 1)))
                     (props-end
                      (save-excursion
                        (if (re-search-forward
                             "^\\(:END:\\|\\*\\)"
                             section-end t)
                            (point)
                          section-end))))
                (unless (save-excursion
                          (re-search-forward
                           "^\\s-*:BOOKABLE:\\s-*false"
                           props-end t))
                  (push name contracts))))))
        (nreverse contracts)))))

(defun kaisho-clock-tasks (customer)
  "Return distinct task descriptions for CUSTOMER from clocks.org."
  (when (file-exists-p (kaisho-clocks-file))
    (with-temp-buffer
      (insert-file-contents (kaisho-clocks-file))
      (let (tasks)
        (while (re-search-forward
                (concat "^\\* \\["
                        (regexp-quote customer)
                        "\\]:\\s-+\\(.+\\)$")
                nil t)
          (push (match-string-no-properties 1) tasks))
        (delete-dups (nreverse tasks))))))


;;; ---------------------------------------------------------------
;;; Clock entry management (internal helpers)
;;; ---------------------------------------------------------------

(defun kaisho--find-or-create-entry (customer task
                                     &optional contract)
  "Find or create a \"* [CUSTOMER]: task\" heading in clocks.org.
When CONTRACT is non-nil, stores it in a :CONTRACT: property.
Leaves point at the beginning of the heading."
  (let ((title (format "[%s]: %s" customer task)))
    (goto-char (point-min))
    (unless (re-search-forward
             (concat "^\\* " (regexp-quote title) "\\s-*$")
             nil t)
      (goto-char (point-min))
      (if (re-search-forward "^\\*" nil t)
          (beginning-of-line)
        (goto-char (point-max)))
      (if contract
          (insert (format (concat "* %s\n"
                                  "  :PROPERTIES:\n"
                                  "  :CONTRACT: %s\n"
                                  "  :END:\n")
                          title contract))
        (insert (format "* %s\n\n" title)))
      (goto-char (point-min))
      (re-search-forward
       (concat "^\\* " (regexp-quote title))))
    (beginning-of-line)))

(defun kaisho--insert-clock-into-logbook (clock-line)
  "Insert CLOCK-LINE into the :LOGBOOK: drawer at point.
Creates the drawer when absent."
  (let ((task-end
         (save-excursion
           (org-end-of-subtree t t) (point))))
    (if (re-search-forward
         "^\\([ \t]*\\):LOGBOOK:" task-end t)
        (let ((indent (match-string 1)))
          (re-search-forward "^[ \t]*:END:" task-end t)
          (beginning-of-line)
          (insert (format "%s%s\n" indent clock-line)))
      (end-of-line)
      (insert (format "\n   :LOGBOOK:\n   %s\n   :END:"
                      clock-line)))))


;;; ---------------------------------------------------------------
;;; Clock in/out
;;; ---------------------------------------------------------------

(defun kaisho--last-task ()
  "Return the heading of the last clocked task, or nil."
  (when org-clock-history
    (let ((marker (car org-clock-history)))
      (when (marker-buffer marker)
        (org-with-point-at marker
          (org-get-heading t t t t))))))

(defun kaisho-clock-toggle ()
  "Toggle the clock on a Kaisho task.

When a clock is running: stop it (cancel if the marker is stale).
When no clock is running: offer to resume the last task or prompt
for customer, optional contract, and task description."
  (interactive)
  (if (org-clocking-p)
      (condition-case _err
          (progn
            (org-clock-out)
            (message "Clock stopped"))
        (error
         (org-clock-cancel)
         (message "Clock cancelled (invalid marker)")))
    (let ((last (kaisho--last-task)))
      (if (and last
               (y-or-n-p (format "Resume \"%s\"? " last)))
          (progn
            (org-clock-in-last)
            (message "Clock resumed: %s" last))
        (kaisho--clock-start-new)))))

(defun kaisho--clock-start-new ()
  "Prompt for customer, contract and task, then start the clock."
  (let* ((file     (kaisho-clocks-file))
         (customer (completing-read "Customer: "
                                    (kaisho-customers)
                                    nil nil))
         (customer (if (string-empty-p customer)
                       "Misc" customer))
         (contracts (kaisho-customer-contracts customer))
         (contract (when contracts
                     (completing-read
                      (format "[%s] Contract: " customer)
                      (cons "- none -" contracts)
                      nil t)))
         (contract (when (and contract
                              (not (string= contract
                                            "- none -")))
                     contract))
         (title (completing-read
                 (format "[%s] Task: " customer)
                 (kaisho-clock-tasks customer)
                 nil nil)))
    (with-current-buffer (find-file-noselect file)
      (when (= (buffer-size) 0)
        (insert "#+TITLE: Clocks\n"
                "#+STARTUP: overview\n\n"))
      (kaisho--find-or-create-entry
       customer title contract)
      (org-clock-in)
      (save-buffer))
    (message "Clock started: [%s]%s %s"
             customer
             (if contract (format " (%s)" contract) "")
             title)))


;;; ---------------------------------------------------------------
;;; Manual backdated clock entry
;;; ---------------------------------------------------------------

(defun kaisho--format-ts (date-str time-str)
  "Build an org inactive timestamp from DATE-STR and TIME-STR.
DATE-STR is YYYY-MM-DD, TIME-STR is HH:MM."
  (let ((enc (encode-time
              0
              (string-to-number (substring time-str 3 5))
              (string-to-number (substring time-str 0 2))
              (string-to-number (substring date-str 8 10))
              (string-to-number (substring date-str 5 7))
              (string-to-number (substring date-str 0 4)))))
    (format-time-string "[%Y-%m-%d %a %H:%M]" enc)))

(defun kaisho--clock-duration (start end)
  "Return HH:MM duration string between START and END (both HH:MM)."
  (let* ((to-mins (lambda (t-str)
                    (+ (* 60 (string-to-number
                              (substring t-str 0 2)))
                       (string-to-number
                        (substring t-str 3 5)))))
         (diff (- (funcall to-mins end)
                  (funcall to-mins start))))
    (format "%d:%02d" (/ diff 60) (% diff 60))))

(defun kaisho-insert-clock-entry ()
  "Insert a past clock entry into clocks.org.
Prompts for customer, contract, task, date, start and end time."
  (interactive)
  (let* ((customer (completing-read "Customer: "
                                    (kaisho-customers)
                                    nil nil))
         (customer (if (string-empty-p customer)
                       "Misc" customer))
         (contracts (kaisho-customer-contracts customer))
         (contract (when contracts
                     (completing-read
                      (format "[%s] Contract: " customer)
                      (cons "- none -" contracts)
                      nil t)))
         (contract (when (and contract
                              (not (string= contract
                                            "- none -")))
                     contract))
         (title (completing-read
                 (format "[%s] Task: " customer)
                 (kaisho-clock-tasks customer)
                 nil nil))
         (date-str (org-read-date nil nil nil "Date: "))
         (start    (read-string "Start (HH:MM): "))
         (end      (read-string "End   (HH:MM): "))
         (ts-start (kaisho--format-ts date-str start))
         (ts-end   (kaisho--format-ts date-str end))
         (dur      (kaisho--clock-duration start end))
         (clock    (format "CLOCK: %s--%s =>  %s"
                           ts-start ts-end dur)))
    (find-file (kaisho-clocks-file))
    (when (= (buffer-size) 0)
      (insert "#+TITLE: Clocks\n"
              "#+STARTUP: overview\n\n"))
    (kaisho--find-or-create-entry customer title contract)
    (kaisho--insert-clock-into-logbook clock)
    (save-buffer)
    (message "Inserted: %s" clock)))


;;; ---------------------------------------------------------------
;;; Clock reporting
;;; ---------------------------------------------------------------

(defun kaisho--today-by-customer ()
  "Return alist of (customer . minutes) for today's clock entries."
  (let ((today (format-time-string "%Y-%m-%d"))
        (result '())
        (current-customer nil))
    (with-current-buffer
        (find-file-noselect (kaisho-clocks-file))
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (cond
           ((looking-at "^\\* \\[\\([^]]+\\)\\]:")
            (setq current-customer
                  (match-string-no-properties 1)))
           ((and current-customer
                 (looking-at
                  (concat "[ \t]*CLOCK: \\["
                          (regexp-quote today)
                          " [A-Za-z]+ [0-9:]+\\]"
                          "--\\[[^]]+\\]"
                          " =>\\s-+\\([0-9]+\\)"
                          ":\\([0-9]+\\)")))
            (let* ((mins (+ (* 60 (string-to-number
                                   (match-string 1)))
                            (string-to-number
                             (match-string 2))))
                   (entry (assoc current-customer result)))
              (if entry
                  (setcdr entry (+ (cdr entry) mins))
                (push (cons current-customer mins)
                      result)))))
          (forward-line 1))))
    (nreverse result)))

(defun kaisho-clock-today-summary ()
  "Show today's clocked time per customer in the minibuffer."
  (interactive)
  (let* ((data  (kaisho--today-by-customer))
         (total (apply #'+ (mapcar #'cdr data))))
    (if (null data)
        (message "No time clocked today")
      (message "Today: %dh%02dm  |  %s"
               (/ total 60) (% total 60)
               (mapconcat
                (lambda (entry)
                  (format "%s %dh%02dm"
                          (car entry)
                          (/ (cdr entry) 60)
                          (% (cdr entry) 60)))
                data "  ")))))

(defun kaisho-clock-goto ()
  "Jump to the currently or most recently clocked task.
Falls back to opening clocks.org when no history is available."
  (interactive)
  (cond
   ((org-clocking-p) (org-clock-goto))
   ((and org-clock-history
         (marker-buffer (car org-clock-history)))
    (org-clock-goto))
   (t
    (find-file (kaisho-clocks-file))
    (message "Opened clocks file (no recent clock)"))))

(defun kaisho-clock-report ()
  "Open clocks.org and update or insert a weekly clock table."
  (interactive)
  (find-file (kaisho-clocks-file))
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
;;; Project tag helpers (for capture templates)
;;; ---------------------------------------------------------------

(defun kaisho--todos-project-tags ()
  "Return unique [CUSTOMER] prefixes found in todos.org."
  (when (file-exists-p (kaisho-todos-file))
    (with-temp-buffer
      (insert-file-contents (kaisho-todos-file))
      (let (tags)
        (while (re-search-forward
                "^\\* [A-Z-]+ \\(\\[[^]]+\\]\\):"
                nil t)
          (push (match-string-no-properties 1) tags))
        (delete-dups (nreverse tags))))))

(defun kaisho-capture-select-project ()
  "Prompt for a [Project] tag; wraps bare names in brackets.
Intended for use inside org capture templates."
  (let* ((tags (kaisho--todos-project-tags))
         (raw  (completing-read "Project: " tags nil nil)))
    (if (string-match-p "^\\[.*\\]$" raw)
        raw
      (format "[%s]" raw))))

(defun kaisho-change-project-tag ()
  "Replace the [Project] prefix on the org heading at point."
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
;;; kai CLI integration
;;; ---------------------------------------------------------------

(defun kaisho-run-command (args)
  "Run the kai CLI with ARGS (a string) in a compilation buffer."
  (let ((cmd (concat kaisho-cli-executable " " args)))
    (compile cmd)))

(defun kaisho-run-command-interactive ()
  "Prompt for kai CLI arguments and run the command."
  (interactive)
  (let ((args (read-string "kai args: ")))
    (kaisho-run-command args)))

(defun kaisho-sync ()
  "Run `kai sync' to sync Kaisho data."
  (interactive)
  (kaisho-run-command "sync"))

(defun kaisho-serve ()
  "Start the Kaisho backend with `kai serve'."
  (interactive)
  (let ((buf (get-buffer-create kaisho-clock-buffer-name)))
    (with-current-buffer buf
      (erase-buffer))
    (start-process "kaisho-serve" buf
                   kaisho-cli-executable "serve")
    (pop-to-buffer buf)
    (message "Kaisho server started")))


;;; ---------------------------------------------------------------
;;; Org-mode configuration helper
;;; ---------------------------------------------------------------

(defun kaisho-configure-org ()
  "Configure org-mode to use Kaisho files.

Call this after setting `kaisho-org-dir'.  Sets org-directory,
default-notes-file, agenda files, clocking persistence and
clock-into-drawer.  Does not touch TODO keywords, capture
templates or agenda views -- configure those in your init file."
  (setq org-directory              kaisho-org-dir
        org-default-notes-file     (kaisho-notes-file))
  (setq org-agenda-files
        (list (kaisho-todos-file) (kaisho-clocks-file)))
  (setq org-clock-persist               'history
        org-clock-persist-query-resume  t
        org-clock-mode-line-total       'current
        org-clock-idle-time             nil
        org-clock-auto-clock-resolution 'when-no-clock-is-running
        org-log-note-clock-out          nil
        org-clock-into-drawer           t
        org-clock-history-length        25
        org-clock-out-when-done         t)
  (org-clock-persistence-insinuate))


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
    (define-key map (kbd "C-c k x") #'org-clock-cancel)
    ;; Files
    (define-key map (kbd "C-c k f t") #'kaisho-open-todos)
    (define-key map (kbd "C-c k f c") #'kaisho-open-clocks)
    (define-key map (kbd "C-c k f n") #'kaisho-open-notes)
    ;; CLI
    (define-key map (kbd "C-c k !") #'kaisho-run-command-interactive)
    map)
  "Keymap for `kaisho-mode'.

Default bindings use C-c k as the prefix:
  t   kaisho-clock-toggle
  s   kaisho-clock-today-summary
  g   kaisho-clock-goto
  i   kaisho-insert-clock-entry
  r   kaisho-clock-report
  x   org-clock-cancel
  f t kaisho-open-todos
  f c kaisho-open-clocks
  f n kaisho-open-notes
  !   kaisho-run-command-interactive")

;;;###autoload
(define-minor-mode kaisho-mode
  "Minor mode for Kaisho productivity integration.

Provides clock management, task navigation and kai CLI access
for the Kaisho local-first productivity app, operating on the
same org files as the Kaisho backend.

\\{kaisho-mode-map}"
  :init-value nil
  :lighter " Kaisho"
  :keymap kaisho-mode-map
  :global t
  :group 'kaisho)

(provide 'kaisho-mode)

;;; kaisho-mode.el ends here
