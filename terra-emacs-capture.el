;;; terra-emacs-capture.el --- the declarative state of a live Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A state is a plist, written to disk as one readable s-expression:
;;
;;   (:terra-emacs 1                    the format version
;;    :backend tab-bar                  the backend it was captured from
;;    :levels ((:id "ops" :name "Operations") ...)
;;    :current "main"                   the workspace shown
;;    :workspaces
;;    ((:name "main" :id "6f1c..." :level "ops"
;;      :parameters ((owner . "pm"))   saved backend parameters
;;      :layout (:split right :sizes (0.5 0.5) :children (...)))
;;     ...))                            in display order
;;
;; A state with `:partial t' names only some workspaces: applying it
;; kills, moves and selects nothing else.
;;
;; A workspace with no :layout is left as it is laid out; one with no
;; :id is matched by name.  `terra-emacs-capture-all' writes the full
;; state of any live Emacs; `terra-emacs-capture' one workspace.

;;; Code:

(require 'cl-lib)
(require 'pp)
(require 'terra-emacs-backend)
(require 'terra-emacs-layout)

(defconst terra-emacs-format-version 1
  "The state format this terra-emacs reads and writes.")

(defun terra-emacs--ws-id (backend name)
  "The id of workspace NAME in BACKEND, assigning one when it has none."
  (or (terra-emacs-backend-id backend name)
      (let ((id (terra-emacs-new-id)))
        (terra-emacs-backend-set-id backend name id)
        id)))

(defun terra-emacs-capture (&optional workspace backend)
  "The state of WORKSPACE (default: the shown one) in BACKEND.
Interactively, show it in a buffer."
  (interactive)
  (let* ((backend (or backend (terra-emacs-current-backend)))
         (name (or workspace (terra-emacs-backend-current backend)))
         (layout (terra-emacs-backend-with-workspace
                  backend name #'terra-emacs-layout-capture))
         (level (terra-emacs-backend-level backend name))
         (params (terra-emacs-backend-parameters backend name))
         (ws (append (list :name name :id (terra-emacs--ws-id backend name))
                     (and level (list :level level))
                     (and params (list :parameters params))
                     (list :layout layout))))
    (when (called-interactively-p 'any) (terra-emacs-show-state ws))
    ws))

(defun terra-emacs--levels (declared workspaces)
  "DECLARED levels plus one for each level WORKSPACES use that none names."
  (let ((levels (copy-sequence declared)))
    (dolist (ws workspaces)
      (let ((level (plist-get ws :level)))
        (when (and level (not (cl-find level levels
                                       :key (lambda (l) (plist-get l :id)) :test #'equal)))
          (setq levels (append levels (list (list :id level :name (format "%s" level))))))))
    levels))

(defun terra-emacs-capture-all (&optional backend)
  "The full state: every workspace of BACKEND, in order, and the levels.
Interactively, show it in a buffer."
  (interactive)
  (let* ((backend (or backend (terra-emacs-current-backend)))
         (workspaces (mapcar (lambda (name) (terra-emacs-capture name backend))
                             (terra-emacs-backend-workspaces backend)))
         (state (list :terra-emacs terra-emacs-format-version
                      :backend backend
                      :levels (terra-emacs--levels (terra-emacs-backend-levels backend)
                                                   workspaces)
                      :current (terra-emacs-backend-current backend)
                      :workspaces workspaces)))
    (when (called-interactively-p 'any) (terra-emacs-show-state state))
    state))

;;;; Files

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
  (let ((tmp (make-temp-file (expand-file-name ".terra-emacs-" (file-name-directory file))))
        (text (concat ";; terra-emacs state -*- mode: lisp-data -*-\n"
                      (terra-emacs-state-string state))))
    (make-directory (file-name-directory file) t)
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

(provide 'terra-emacs-capture)
;;; terra-emacs-capture.el ends here
