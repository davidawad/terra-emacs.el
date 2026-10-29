;;; terra-emacs-sets.el --- named sets, and applying one at start -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Named sets are state files in `terra-emacs-directory', NAME.eld:
;; `terra-emacs-apply-set' NAME converges on one.  This engine only
;; applies them; writing one from the live Emacs is the exporter's job
;; (terra-emacs-capture's `terra-emacs-capture-save' and
;; `terra-emacs-capture-autosave-mode').
;;
;; `terra-emacs-restore-at-start' applies the set named
;; `terra-emacs-autosave-name' once Emacs has started (in a daemon, once
;; its first client frame exists).  `terra-emacs-autosave--restored'
;; tells an autosaver whether that apply has run, so a fresh Emacs never
;; writes its empty state over the one it is about to restore.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-state)
(require 'terra-emacs-plan)

(defvar server-after-make-frame-hook)

(defcustom terra-emacs-directory (locate-user-emacs-file "terra-emacs/")
  "Where named sets (NAME.eld state files) live."
  :type 'directory :group 'terra-emacs)

(defcustom terra-emacs-autosave-name "autosave"
  "The set applied at start (and the one an autosaver writes)."
  :type 'string :group 'terra-emacs)

(defcustom terra-emacs-autosave-restore t
  "Non-nil: `terra-emacs-restore-at-start' applies the autosave set."
  :type 'boolean :group 'terra-emacs)

(defvar terra-emacs-autosave--restored nil
  "Non-nil once this Emacs ran (or skipped) its start-up apply.")

(defvar terra-emacs-autosave-after-restore-hook nil
  "Run after the start-up apply, with the plan it ran as argument.")

;;;; Named sets

(defun terra-emacs-set-file (name)
  "The state file of the set NAME."
  (expand-file-name (concat name ".eld") terra-emacs-directory))

(defun terra-emacs-sets ()
  "The names of the saved sets."
  (and (file-directory-p terra-emacs-directory)
       (mapcar #'file-name-base (directory-files terra-emacs-directory nil "\\`[^.].*\\.eld\\'"))))

(defun terra-emacs-read-set-name (prompt)
  "Read a set name with PROMPT."
  (completing-read prompt (terra-emacs-sets) nil nil nil nil terra-emacs-autosave-name))

;;;###autoload
(defun terra-emacs-apply-set (name &optional dry-run)
  "Converge on the set NAME; with DRY-RUN only plan.  Return the plan."
  (interactive (list (terra-emacs-read-set-name "Apply set: ") current-prefix-arg))
  (let ((plan (terra-emacs-apply (terra-emacs-set-file name) dry-run)))
    (when (called-interactively-p 'any) (terra-emacs-plan-show plan dry-run))
    plan))

;;;; Restore at start

(defun terra-emacs-autosave-frame-ready-p ()
  "Non-nil when a frame can show workspaces (a daemon waits for a client)."
  (or (not (daemonp))
      (cl-some (lambda (f) (frame-parameter f 'client)) (frame-list))))

(defun terra-emacs-autosave-restore-now ()
  "Apply the autosave set once per Emacs; the plan it ran."
  (unless terra-emacs-autosave--restored
    (remove-hook 'server-after-make-frame-hook #'terra-emacs-autosave-restore-now)
    (remove-hook 'emacs-startup-hook #'terra-emacs-autosave-restore-now)
    (setq terra-emacs-autosave--restored t)
    (let ((file (terra-emacs-set-file terra-emacs-autosave-name)))
      (when (file-exists-p file)
        (condition-case err
            (let ((plan (terra-emacs-apply file)))
              (run-hook-with-args 'terra-emacs-autosave-after-restore-hook plan)
              plan)
          (error (message "terra-emacs: restoring %s failed: %s"
                          file (error-message-string err))
                 nil))))))

;;;###autoload
(defun terra-emacs-restore-at-start ()
  "Apply the autosave set once Emacs can show it, once per Emacs.
Now when Emacs has started and has a frame; else on
`emacs-startup-hook', or in a daemon on `server-after-make-frame-hook'.
Does nothing when `terra-emacs-autosave-restore' is nil."
  (when (and terra-emacs-autosave-restore (not terra-emacs-autosave--restored))
    (cond ((and after-init-time (terra-emacs-autosave-frame-ready-p))
           (terra-emacs-autosave-restore-now))
          ((daemonp)
           (add-hook 'server-after-make-frame-hook #'terra-emacs-autosave-restore-now))
          (t (add-hook 'emacs-startup-hook #'terra-emacs-autosave-restore-now)))))

;;;###autoload
(defun terra-emacs-restore-autosave ()
  "Converge on the autosave set now; the plan.
The first call in an Emacs is its start-up apply."
  (interactive)
  (if (not terra-emacs-autosave--restored)
      (terra-emacs-autosave-restore-now)
    (let ((file (terra-emacs-set-file terra-emacs-autosave-name)))
      (and (file-exists-p file) (terra-emacs-apply file)))))

(provide 'terra-emacs-sets)
;;; terra-emacs-sets.el ends here
