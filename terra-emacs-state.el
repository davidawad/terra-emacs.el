;;; terra-emacs-state.el --- the state format: read, write, show -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A state is a plist, written to disk as one readable s-expression:
;;
;;   (:terra-emacs 1                    the format version
;;    :backend tab-bar                  where it was captured (informational)
;;    :levels ((:id "ops" :name "Operations") ...)
;;    :current "main"                   the workspace shown
;;    :workspaces
;;    ((:name "main" :id "6f1c..." :level "ops"
;;      :parameters ((owner . "pm"))   saved backend parameters
;;      :layout (:split right :sizes (0.5 0.5) :children (...)))
;;     ...))                            in display order
;;
;; A state with `:partial t' names only some workspaces: applying it
;; kills, moves and selects nothing else.  A workspace with no :layout
;; is left as it is laid out; one with no :id is matched by name.
;;
;; Write one by hand, or have the terra-emacs-capture package capture
;; one from a live Emacs.

;;; Code:

(require 'pp)
(require 'terra-emacs-layout)

(defconst terra-emacs-format-version 1
  "The state format this terra-emacs reads and writes.")

(defun terra-emacs-state-clean (state)
  "STATE (or one workspace's) without what never goes in a state file."
  (let ((clean (lambda (ws)
                 (let ((copy (copy-sequence ws)))
                   (if (plist-member ws :layout)
                       (plist-put copy :layout (terra-emacs-layout-clean (plist-get ws :layout)))
                     copy)))))
    (if (plist-member state :workspaces)
        (let ((copy (copy-sequence state)))
          (plist-put copy :workspaces (mapcar clean (plist-get state :workspaces))))
      (funcall clean state))))

(defun terra-emacs-state-string (state)
  "STATE printed readably."
  (let ((print-length nil) (print-level nil) (print-circle nil)
        (print-escape-newlines t))
    (pp-to-string (terra-emacs-state-clean state))))

(defun terra-emacs-write-state (state file)
  "Write STATE to FILE (atomically: a temp file renamed over it)."
  (make-directory (file-name-directory file) t)
  (let ((tmp (make-temp-file (expand-file-name ".terra-emacs-" (file-name-directory file))))
        (text (concat ";; terra-emacs state -*- mode: lisp-data; coding: utf-8-emacs-unix -*-\n"
                      (terra-emacs-state-string state)))
        ;; Never ask: state holds arbitrary buffer names and titles, and an
        ;; autosave timer that prompts for a coding system wedges the minibuffer.
        (coding-system-for-write 'utf-8-emacs-unix))
    (with-temp-file tmp (insert text))
    (rename-file tmp file t)
    file))

(defun terra-emacs-read-state (file)
  "The state in FILE; an error when it is not one."
  (let ((state (with-temp-buffer
                 (insert-file-contents file)
                 (read (current-buffer)))))
    (unless (and (consp state) (plist-get state :terra-emacs))
      (error "terra-emacs: %s holds no terra-emacs state" file))
    (when (> (plist-get state :terra-emacs) terra-emacs-format-version)
      (error "terra-emacs: %s is format %s; this terra-emacs reads up to %s"
             file (plist-get state :terra-emacs) terra-emacs-format-version))
    state))

(defun terra-emacs-show-state (state)
  "Show STATE in the buffer *terra-emacs-state*."
  (with-current-buffer (get-buffer-create "*terra-emacs-state*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (terra-emacs-state-string state))
      (lisp-data-mode)
      (goto-char (point-min)))
    (display-buffer (current-buffer))))

(provide 'terra-emacs-state)
;;; terra-emacs-state.el ends here
