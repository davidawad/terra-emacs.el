;;; terra-emacs-handlers.el --- restoring eshell, eat and vterm leaves -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Leaf handlers for buffers whose own bookmark support does not bring
;; them back as they were:
;;
;;   eshell  (handler . terra-emacs-eshell-bookmark-handler)
;;           buffer-name, cwd.
;;   eat     (handler . terra-emacs-eat-bookmark-handler)
;;           buffer-name, cwd, argv (default: $SHELL).
;;   vterm   (handler . terra-emacs-vterm-bookmark-handler)
;;           buffer-name, cwd, command (default: `vterm-shell').
;;
;; Restoring reuses a buffer of the same name whose process runs the
;; same command, so a process starts only where none runs.  A live
;; terminal whose command this Emacs does not know (started by hand,
;; with no exporter recording commands) is reused too: terra-emacs
;; never kills a process it cannot identify.
;;
;; This file restores.  Reading a live terminal's command back into a
;; record is the capture side, in the terra-emacs-capture package.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

(defun terra-emacs-handlers--stop (buffer)
  "End BUFFER's process, if any, without asking."
  (let ((p (get-buffer-process buffer)))
    (when p (set-process-query-on-exit-flag p nil) (delete-process p))))

;;;; eshell

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

(put 'terra-emacs-eshell-bookmark-handler 'terra-emacs-leaf-key-function
     (lambda (record) (list 'eshell (terra-emacs-leaf-prop record 'buffer-name))))

;;;; eat

(defvar-local terra-emacs-eat-argv nil
  "The command line this eat buffer's process was started with, when known.")
(put 'terra-emacs-eat-argv 'permanent-local t)

(defun terra-emacs-eat-default-argv ()
  "The command an eat leaf with no argv runs: the login shell."
  (list (or (getenv "SHELL") shell-file-name)))

(defun terra-emacs-eat-start (name dir argv &optional environment)
  "Buffer NAME running ARGV in eat, in DIR, with ENVIRONMENT if non-nil.
A buffer NAME whose live process runs ARGV, or a command not known, is
returned as it is."
  (require 'eat)
  (let* ((buf (get-buffer name))
         (have (and buf (buffer-local-value 'terra-emacs-eat-argv buf))))
    (if (and buf (terra-emacs-handlers--live-p buf) (or (null have) (equal have argv)))
        buf
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (let ((default-directory (terra-emacs-handlers--dir dir))
              (process-environment (or environment process-environment)))
          (terra-emacs-handlers--stop buf)
          (eat-mode)
          (eat-exec buf (string-trim name "\\*" "\\*") (car argv) nil (cdr argv))
          (setq terra-emacs-eat-argv argv))
        ;; Outside the `let': its binding of the buffer-local value is
        ;; undone on exit, which would leave the buffer in the caller's
        ;; directory and make the next capture record the wrong cwd.
        (setq default-directory (terra-emacs-handlers--dir dir)))
      buf)))

(defun terra-emacs-eat-bookmark-handler (record)
  "Make RECORD's eat terminal current, starting its command when not running."
  (set-buffer (terra-emacs-eat-start (terra-emacs-leaf-prop record 'buffer-name)
                                     (terra-emacs-leaf-prop record 'cwd)
                                     (or (terra-emacs-leaf-prop record 'argv)
                                         (terra-emacs-eat-default-argv)))))

(put 'terra-emacs-eat-bookmark-handler 'terra-emacs-leaf-process t)
(put 'terra-emacs-eat-bookmark-handler 'terra-emacs-leaf-key-function
     (lambda (record)
       (list 'eat (terra-emacs-leaf-prop record 'buffer-name)
             (or (terra-emacs-leaf-prop record 'argv) (terra-emacs-eat-default-argv)))))

;;;; vterm

(defvar-local terra-emacs-vterm-command nil
  "The command this vterm buffer was started with, when known.")
(put 'terra-emacs-vterm-command 'permanent-local t)

(defun terra-emacs-vterm--default ()
  "The command a vterm leaf with no command runs."
  (or (bound-and-true-p vterm-shell) shell-file-name))

(defun terra-emacs-vterm-bookmark-handler (record)
  "Make RECORD's vterm current, starting its command when not running."
  (require 'vterm)
  (let* ((name (terra-emacs-leaf-prop record 'buffer-name))
         (cmd (or (terra-emacs-leaf-prop record 'command) (terra-emacs-vterm--default)))
         (buf (get-buffer name))
         (have (and buf (buffer-local-value 'terra-emacs-vterm-command buf))))
    (unless (and buf (terra-emacs-handlers--live-p buf) (or (null have) (equal have cmd)))
      (setq buf (get-buffer-create name))
      (with-current-buffer buf
        (terra-emacs-handlers--stop buf)
        (setq default-directory (terra-emacs-handlers--dir (terra-emacs-leaf-prop record 'cwd)))
        (let ((vterm-shell cmd)) (vterm-mode))
        (setq terra-emacs-vterm-command cmd)))
    (set-buffer buf)))

(put 'terra-emacs-vterm-bookmark-handler 'terra-emacs-leaf-process t)
(put 'terra-emacs-vterm-bookmark-handler 'terra-emacs-leaf-key-function
     (lambda (record)
       (list 'vterm (terra-emacs-leaf-prop record 'buffer-name)
             (or (terra-emacs-leaf-prop record 'command) (terra-emacs-vterm--default)))))

(provide 'terra-emacs-handlers)
;;; terra-emacs-handlers.el ends here
