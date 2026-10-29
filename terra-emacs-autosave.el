;;; terra-emacs-autosave.el --- named sets, autosave, restore at start -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A restart should change nothing.  `terra-emacs-autosave-mode' writes
;; the full state (`terra-emacs-capture-all') to the set named
;; `terra-emacs-autosave-name' when Emacs exits (`kill-emacs-hook') and
;; every `terra-emacs-autosave-interval' seconds on a plain repeating
;; timer (idle timers do not fire in every Emacs build, neomacs among
;; them), and applies that set when Emacs starts.  Until the start-up
;; apply has run, nothing is autosaved, so a fresh Emacs never writes
;; its empty state over the one it is about to restore.
;;
;; Named sets are state files in `terra-emacs-directory':
;; `terra-emacs-save' NAME writes one, `terra-emacs-apply-set' NAME
;; converges on one.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-capture)
(require 'terra-emacs-plan)

(defcustom terra-emacs-directory (locate-user-emacs-file "terra-emacs/")
  "Where named sets (NAME.eld state files) live."
  :type 'directory :group 'terra-emacs)

(defcustom terra-emacs-autosave-name "autosave"
  "The set autosave writes and a start applies."
  :type 'string :group 'terra-emacs)

(defcustom terra-emacs-autosave-interval 300
  "Seconds between autosaves while `terra-emacs-autosave-mode' is on."
  :type 'integer :group 'terra-emacs)

(defcustom terra-emacs-autosave-restore t
  "Non-nil: turning `terra-emacs-autosave-mode' on at start applies the autosave."
  :type 'boolean :group 'terra-emacs)

(defvar terra-emacs-autosave--timer nil "The autosave timer.")

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

(defun terra-emacs--read-set-name (prompt)
  "Read a set name with PROMPT."
  (completing-read prompt (terra-emacs-sets) nil nil nil nil terra-emacs-autosave-name))

;;;###autoload
(defun terra-emacs-save (&optional name)
  "Write the full state as the set NAME (default: the autosave set); its file."
  (interactive (list (terra-emacs--read-set-name "Save set: ")))
  (let ((file (terra-emacs-write-state (terra-emacs-capture-all)
                                       (terra-emacs-set-file (or name terra-emacs-autosave-name)))))
    (when (called-interactively-p 'any) (message "terra-emacs: saved %s" file))
    file))

;;;###autoload
(defun terra-emacs-apply-set (name &optional dry-run)
  "Converge on the set NAME; with DRY-RUN only plan.  Return the plan."
  (interactive (list (terra-emacs--read-set-name "Apply set: ") current-prefix-arg))
  (let ((plan (terra-emacs-apply (terra-emacs-set-file name) dry-run)))
    (when (called-interactively-p 'any) (terra-emacs-plan-show plan dry-run))
    plan))

;;;; Autosave

(defun terra-emacs-autosave-save ()
  "Write the autosave set, unless a start-up apply is still pending.
Errors are reported, never raised: this runs on `kill-emacs-hook'."
  (when (or terra-emacs-autosave--restored (not terra-emacs-autosave-restore))
    (condition-case err
        (terra-emacs-save terra-emacs-autosave-name)
      (error (message "terra-emacs: autosave failed: %s" (error-message-string err))))))

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
(defun terra-emacs-restore-autosave ()
  "Converge on the autosave set now; the plan.
The first call in an Emacs is its start-up apply (see
`terra-emacs-autosave-save', which waits for it)."
  (interactive)
  (if (not terra-emacs-autosave--restored)
      (terra-emacs-autosave-restore-now)
    (let ((file (terra-emacs-set-file terra-emacs-autosave-name)))
      (and (file-exists-p file) (terra-emacs-apply file)))))

;;;###autoload
(define-minor-mode terra-emacs-autosave-mode
  "Save the workspace state on exit and every few minutes; restore it at start."
  :global t :group 'terra-emacs
  (when terra-emacs-autosave--timer
    (cancel-timer terra-emacs-autosave--timer)
    (setq terra-emacs-autosave--timer nil))
  (remove-hook 'kill-emacs-hook #'terra-emacs-autosave-save)
  (when terra-emacs-autosave-mode
    (add-hook 'kill-emacs-hook #'terra-emacs-autosave-save)
    (setq terra-emacs-autosave--timer
          (run-at-time terra-emacs-autosave-interval terra-emacs-autosave-interval
                       #'terra-emacs-autosave-save))
    (when (and terra-emacs-autosave-restore (not terra-emacs-autosave--restored))
      (cond ((and after-init-time (terra-emacs-autosave-frame-ready-p))
             (terra-emacs-autosave-restore-now))
            ((daemonp)
             (add-hook 'server-after-make-frame-hook #'terra-emacs-autosave-restore-now))
            (t (add-hook 'emacs-startup-hook #'terra-emacs-autosave-restore-now))))))

(provide 'terra-emacs-autosave)
;;; terra-emacs-autosave.el ends here
