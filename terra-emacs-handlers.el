;;; terra-emacs-handlers.el --- leaves for eshell, eat and vterm -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Leaf handlers for buffers whose own bookmark support does not bring
;; them back as they were:
;;
;;   eshell  its cwd and buffer name (eshell's own bookmark reopens
;;           *eshell* whatever the name was).
;;   eat     its cwd and the command it runs; eat has no bookmark
;;           support at all, so this also gives eat buffers a
;;           `bookmark-make-record-function'.
;;   vterm   its cwd and the command it runs (`vterm-shell').
;;
;; Restoring reuses a buffer of the same name that still runs the same
;; command, so a process starts only where none runs.  A captured leaf
;; whose process has ended is marked stale, so a plan restarts it.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-leaf)

(defvar eshell-buffer-name)
(defvar vterm-shell)
(declare-function eshell "eshell" (&optional arg))
(declare-function eat-mode "eat" ())
(declare-function eat-exec "eat" (buffer name command startfile switches))
(declare-function vterm-mode "vterm" ())

(defun terra-emacs-handlers--dir (dir)
  "DIR when it is an existing directory, else the home directory."
  (file-name-as-directory
   (if (and dir (file-directory-p dir)) (expand-file-name dir) (expand-file-name "~"))))

(defun terra-emacs-handlers--live-p (buffer)
  "Non-nil when BUFFER's process runs."
  (process-live-p (get-buffer-process buffer)))

;;;; eshell

(defun terra-emacs-eshell-capture (buffer)
  "The leaf record of BUFFER when it is an eshell."
  (with-current-buffer buffer
    (when (derived-mode-p 'eshell-mode)
      (terra-emacs-leaf-make (buffer-name) 'handler 'terra-emacs-eshell-bookmark-handler
                             'buffer-name (buffer-name) 'cwd default-directory
                             'terra-key (list 'eshell (buffer-name))))))

(defun terra-emacs-eshell-bookmark-handler (record)
  "Make RECORD's eshell current: the live one by its name, else a new one."
  (let* ((name (terra-emacs-leaf-prop record 'buffer-name))
         (buf (get-buffer name)))
    (set-buffer
     (if (and buf (eq (buffer-local-value 'major-mode buf) 'eshell-mode))
         buf
       (require 'eshell)
       (let ((default-directory (terra-emacs-handlers--dir (terra-emacs-leaf-prop record 'cwd)))
             (eshell-buffer-name name))
         (save-window-excursion (eshell)))))))

;;;; eat

(defvar-local terra-emacs-eat-argv nil
  "The command line this eat buffer's process was started with.")
(put 'terra-emacs-eat-argv 'permanent-local t)

(defun terra-emacs-eat--note-argv (process)
  "Remember PROCESS's command line (`eat-exec-hook')."
  (with-current-buffer (process-buffer process)
    (let ((cmd (process-command process)))
      ;; eat runs: env sh -c SCRIPT .. COMMAND SWITCHES...
      (setq terra-emacs-eat-argv
            (if (and (equal (car cmd) "/usr/bin/env") (equal (nth 4 cmd) ".."))
                (nthcdr 5 cmd)
              cmd)))))

(defun terra-emacs-eat-argv (buffer)
  "The command line BUFFER's eat process runs, or ran."
  (or (buffer-local-value 'terra-emacs-eat-argv buffer)
      (let ((p (get-buffer-process buffer)))
        (and p (with-current-buffer buffer
                 (terra-emacs-eat--note-argv p)
                 terra-emacs-eat-argv)))))

(defun terra-emacs-eat-bookmark-make-record ()
  "The bookmark record of the current eat buffer: its cwd and command."
  (let ((argv (terra-emacs-eat-argv (current-buffer))))
    (apply #'terra-emacs-leaf-make (buffer-name)
           'handler 'terra-emacs-eat-bookmark-handler
           'buffer-name (buffer-name) 'cwd default-directory 'argv argv
           'terra-key (list 'eat (buffer-name) argv)
           (unless (terra-emacs-handlers--live-p (current-buffer)) (list 'terra-stale t)))))

(defun terra-emacs-eat-capture (buffer)
  "The leaf record of BUFFER when it is an eat terminal."
  (with-current-buffer buffer
    (when (derived-mode-p 'eat-mode)
      (terra-emacs-eat-bookmark-make-record))))

(defun terra-emacs-eat-start (name dir argv &optional environment)
  "Buffer NAME running ARGV in eat, in DIR, with ENVIRONMENT if non-nil.
A buffer NAME whose process still runs ARGV is returned as it is."
  (require 'eat)
  (let ((buf (get-buffer name)))
    (if (and buf (terra-emacs-handlers--live-p buf) (equal (terra-emacs-eat-argv buf) argv))
        buf
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (let ((default-directory (terra-emacs-handlers--dir dir))
              (process-environment (or environment process-environment)))
          (let ((p (get-buffer-process buf)))
            (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
          (eat-mode)
          (setq default-directory (terra-emacs-handlers--dir dir))
          (eat-exec buf (string-trim name "\\*" "\\*") (car argv) nil (cdr argv))
          (terra-emacs-eat--note-argv (get-buffer-process buf))))
      buf)))

(defun terra-emacs-eat-bookmark-handler (record)
  "Make RECORD's eat terminal current, starting its command when not running."
  (set-buffer (terra-emacs-eat-start (terra-emacs-leaf-prop record 'buffer-name)
                                     (terra-emacs-leaf-prop record 'cwd)
                                     (or (terra-emacs-leaf-prop record 'argv)
                                         (list (or (getenv "SHELL") shell-file-name))))))

(defun terra-emacs-eat--bookmarkable ()
  "Give this eat buffer bookmark support (`eat-mode-hook')."
  (setq-local bookmark-make-record-function #'terra-emacs-eat-bookmark-make-record))

;;;; vterm

(defvar-local terra-emacs-vterm-command nil
  "The command this vterm buffer was started with.")
(put 'terra-emacs-vterm-command 'permanent-local t)

(defun terra-emacs-vterm--command (buffer)
  "The command BUFFER's vterm runs.
vterm wraps `vterm-shell' in a shell line of its own, so a vterm this
package did not start reports `vterm-shell'."
  (or (buffer-local-value 'terra-emacs-vterm-command buffer)
      (bound-and-true-p vterm-shell)))

(defun terra-emacs-vterm-capture (buffer)
  "The leaf record of BUFFER when it is a vterm."
  (with-current-buffer buffer
    (when (derived-mode-p 'vterm-mode)
      (let ((cmd (terra-emacs-vterm--command buffer)))
        (apply #'terra-emacs-leaf-make (buffer-name)
               'handler 'terra-emacs-vterm-bookmark-handler
               'buffer-name (buffer-name) 'cwd default-directory 'command cmd
               'terra-key (list 'vterm (buffer-name) cmd)
               (unless (terra-emacs-handlers--live-p buffer) (list 'terra-stale t)))))))

(defun terra-emacs-vterm-bookmark-handler (record)
  "Make RECORD's vterm current, starting its command when not running."
  (require 'vterm)
  (let* ((name (terra-emacs-leaf-prop record 'buffer-name))
         (cmd (or (terra-emacs-leaf-prop record 'command) vterm-shell))
         (buf (get-buffer name)))
    (unless (and buf (terra-emacs-handlers--live-p buf)
                 (equal (terra-emacs-vterm--command buf) cmd))
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (let ((p (get-buffer-process buf)))
          (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
        (setq default-directory (terra-emacs-handlers--dir (terra-emacs-leaf-prop record 'cwd)))
        (let ((vterm-shell cmd)) (vterm-mode))
        (setq terra-emacs-vterm-command cmd)))
    (set-buffer buf)))

;;;; Installing

(defun terra-emacs-handlers-install ()
  "Put the handlers on `terra-emacs-leaf-capture-functions'; give eat bookmarks."
  (add-hook 'terra-emacs-leaf-capture-functions #'terra-emacs-eshell-capture)
  (add-hook 'terra-emacs-leaf-capture-functions #'terra-emacs-eat-capture)
  (add-hook 'terra-emacs-leaf-capture-functions #'terra-emacs-vterm-capture)
  (add-hook 'eat-exec-hook #'terra-emacs-eat--note-argv)
  (add-hook 'eat-mode-hook #'terra-emacs-eat--bookmarkable))

(terra-emacs-handlers-install)

(provide 'terra-emacs-handlers)
;;; terra-emacs-handlers.el ends here
