;;; terra-emacs-leaf.el --- what a window shows, as a bookmark record -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A leaf of a layout is a bookmark record, (NAME . ALIST), so any mode
;; with bookmark support (files, dired, Info, help, PDFs, ...) captures
;; and restores for free through `bookmark-make-record' and
;; `bookmark-handle-bookmark'.  Modes without one get a handler on
;; `terra-emacs-leaf-capture-functions' (terra-emacs-handlers.el writes
;; them for eshell, eat and vterm; terra-emacs-claude.el for Claude
;; Code); anything else comes back as a buffer of the same name.
;;
;; terra-emacs adds three properties to a record:
;;
;;   buffer-name  the buffer's name when captured.
;;   terra-key    the leaf's identity, compared to decide whether a
;;                window already shows the right thing (default: the
;;                handler plus the file, or plus the buffer name).
;;   terra-stale  set on a captured leaf whose process is gone, so a
;;                plan restarts it; never written to a state file.

;;; Code:

(require 'cl-lib)
(require 'bookmark)

(defvar terra-emacs-leaf-capture-functions nil
  "Functions of a buffer returning its leaf record, or nil to pass.
The first non-nil answer wins; add a handler with `add-hook'.")

(defconst terra-emacs-leaf-dropped-properties
  '(front-context-string rear-context-string front-context-region-string
    rear-context-region-string last-modified defaults annotation)
  "Bookmark properties a leaf record leaves out: they change with every edit.")

(defun terra-emacs-leaf-prop (record prop)
  "Property PROP of the leaf RECORD."
  (alist-get prop (cdr record)))

(defun terra-emacs-leaf-make (name &rest props)
  "A leaf record NAME with the property plist PROPS."
  (cons name (cl-loop for (k v) on props by #'cddr collect (cons k v))))

(defun terra-emacs-leaf--bookmark (buffer)
  "BUFFER's own bookmark record, trimmed, or nil when it has none."
  (with-current-buffer buffer
    (when (or buffer-file-name
              (bound-and-true-p dired-directory)
              (not (eq bookmark-make-record-function #'bookmark-make-record-default)))
      (let ((rec (ignore-errors (bookmark-make-record))))
        (when (consp rec)
          (cons (buffer-name)
                (append (cl-remove-if (lambda (c)
                                        (or (memq (car-safe c) terra-emacs-leaf-dropped-properties)
                                            (eq (car-safe c) 'buffer-name)))
                                      (if (stringp (car rec)) (cdr rec) rec))
                        (list (cons 'buffer-name (buffer-name))))))))))

(defun terra-emacs-leaf-capture (buffer)
  "The leaf record that brings BUFFER back."
  (or (run-hook-with-args-until-success 'terra-emacs-leaf-capture-functions buffer)
      (terra-emacs-leaf--bookmark buffer)
      (terra-emacs-leaf-make (buffer-name buffer)
                             'handler 'terra-emacs-leaf-buffer-handler
                             'buffer-name (buffer-name buffer))))

(defun terra-emacs-leaf-buffer-handler (record)
  "Make RECORD's buffer, by name, current (creating it empty when gone)."
  (set-buffer (get-buffer-create (terra-emacs-leaf-prop record 'buffer-name))))

(defun terra-emacs-leaf-key (record)
  "The identity of the leaf RECORD: two leaves with one key show one thing."
  (or (terra-emacs-leaf-prop record 'terra-key)
      (let ((handler (terra-emacs-leaf-prop record 'handler))
            (file (terra-emacs-leaf-prop record 'filename)))
        (cond (file (list (or handler 'file) (expand-file-name file)))
              ((eq handler 'terra-emacs-leaf-buffer-handler)
               (list 'buffer (terra-emacs-leaf-prop record 'buffer-name)))
              (t (list handler (terra-emacs-leaf-prop record 'buffer-name)))))))

(defun terra-emacs-leaf-stale-p (record)
  "Non-nil when the captured RECORD's process is gone."
  (terra-emacs-leaf-prop record 'terra-stale))

(defun terra-emacs-leaf-clean (record)
  "RECORD without what never goes in a state file."
  (cons (car record) (cl-remove 'terra-stale (cdr record) :key #'car-safe)))

(defun terra-emacs-leaf--placeholder (record why)
  "A buffer saying RECORD could not come back, and WHY."
  (let ((buf (get-buffer-create (format "*terra-emacs: %s*" (car record)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "terra-emacs could not restore %S:\n%s\n" (car record) why)))
      (special-mode))
    (message "terra-emacs: %s: %s" (car record) why)
    buf))

(defun terra-emacs-leaf-restore (record)
  "The buffer RECORD brings back (a placeholder when it cannot)."
  (let ((file (terra-emacs-leaf-prop record 'filename)))
    (if (and file (not (file-remote-p file)) (not (file-exists-p file)))
        (terra-emacs-leaf--placeholder record (format "%s does not exist" file))
      (condition-case err
          (save-window-excursion
            (save-current-buffer
              (bookmark-handle-bookmark record)
              (current-buffer)))
        (error (terra-emacs-leaf--placeholder record (error-message-string err)))))))

(provide 'terra-emacs-leaf)
;;; terra-emacs-leaf.el ends here
