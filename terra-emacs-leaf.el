;;; terra-emacs-leaf.el --- what a window shows, as a bookmark record -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A leaf of a layout is a bookmark record, (NAME . ALIST), so any mode
;; with bookmark support (files, dired, Info, help, PDFs, ...) restores
;; for free through `bookmark-handle-bookmark'.  Modes without one get a
;; handler (terra-emacs-handlers.el for eshell, eat and vterm;
;; terra-emacs-claude.el for Claude Code); anything else comes back as a
;; buffer of the same name.
;;
;; terra-emacs reads three properties of a record besides the handler's:
;;
;;   buffer-name  the buffer's name.
;;   terra-key    an explicit identity, overriding the one the handler's
;;                `terra-emacs-leaf-key-function' property computes.
;;   terra-stale  set on an observed leaf whose process is gone, so a
;;                plan restarts it; never written to a state file.
;;
;; To decide whether a window already shows the right thing, a plan
;; observes it (`terra-emacs-leaf-observe'): the record a capture
;; handler on `terra-emacs-leaf-capture-functions' gives (the
;; terra-emacs-capture package installs them), else the record this
;; engine restored the buffer from, else what the buffer visits.

;;; Code:

(require 'cl-lib)
(require 'bookmark)

(defvar terra-emacs-leaf-capture-functions nil
  "Functions of a buffer returning its leaf record, or nil to pass.
The first non-nil answer wins; add a handler with `add-hook'.  The
engine only reads them; an exporter such as terra-emacs-capture fills
them.")

(defvar-local terra-emacs-leaf-record nil
  "The leaf record this buffer was restored from.")
(put 'terra-emacs-leaf-record 'permanent-local t)

(defvar-local terra-emacs-leaf-placeholder nil
  "Non-nil in a buffer standing in for a leaf that did not come back.")
(put 'terra-emacs-leaf-placeholder 'permanent-local t)

(defun terra-emacs-leaf-prop (record prop)
  "Property PROP of the leaf RECORD."
  (alist-get prop (cdr record)))

(defun terra-emacs-leaf-make (name &rest props)
  "A leaf record NAME with the property plist PROPS."
  (cons name (cl-loop for (k v) on props by #'cddr collect (cons k v))))

(defun terra-emacs-leaf-buffer-handler (record)
  "Make RECORD's buffer, by name, current (creating it empty when gone)."
  (set-buffer (get-buffer-create (or (terra-emacs-leaf-prop record 'buffer-name) (car record)))))

;;;; Identity

(defun terra-emacs-leaf--path (file)
  "FILE expanded, a directory with its trailing slash."
  (let ((f (expand-file-name file)))
    (if (file-directory-p f) (file-name-as-directory f) f)))

(defun terra-emacs-leaf-key (record)
  "The identity of the leaf RECORD: two leaves with one key show one thing."
  (let* ((handler (terra-emacs-leaf-prop record 'handler))
         (fn (and (symbolp handler) handler (get handler 'terra-emacs-leaf-key-function)))
         (file (terra-emacs-leaf-prop record 'filename)))
    (cond ((terra-emacs-leaf-prop record 'terra-key))
          (fn (funcall fn record))
          (file (list 'file (terra-emacs-leaf--path file)))
          (t (list handler (or (terra-emacs-leaf-prop record 'buffer-name) (car record)))))))

(put 'terra-emacs-leaf-buffer-handler 'terra-emacs-leaf-key-function
     (lambda (record)
       (list 'buffer (or (terra-emacs-leaf-prop record 'buffer-name) (car record)))))

(defun terra-emacs-leaf-process-p (record)
  "Non-nil when RECORD's handler runs a process (its `terra-emacs-leaf-process')."
  (let ((handler (terra-emacs-leaf-prop record 'handler)))
    (and (symbolp handler) handler (get handler 'terra-emacs-leaf-process))))

(defun terra-emacs-leaf-stale-p (record)
  "Non-nil when the observed RECORD's process is gone."
  (terra-emacs-leaf-prop record 'terra-stale))

(defun terra-emacs-leaf-clean (record)
  "RECORD without what never goes in a state file."
  (cons (car record) (cl-remove 'terra-stale (cdr record) :key #'car-safe)))

;;;; Observing

(defun terra-emacs-leaf--visit-record (buffer)
  "A record naming what BUFFER visits: its file, its directory, or itself."
  (with-current-buffer buffer
    (let ((file (or buffer-file-name
                    (let ((d (bound-and-true-p dired-directory)))
                      (if (consp d) (car d) d)))))
      (if file
          (terra-emacs-leaf-make (buffer-name) 'filename (terra-emacs-leaf--path file)
                                 'buffer-name (buffer-name))
        (terra-emacs-leaf-make (buffer-name) 'handler 'terra-emacs-leaf-buffer-handler
                               'buffer-name (buffer-name))))))

(defun terra-emacs-leaf-mark-stale (record buffer)
  "RECORD, marked stale when it runs a process and BUFFER's has ended."
  (if (and (terra-emacs-leaf-process-p record)
           (not (terra-emacs-leaf-stale-p record))
           (not (process-live-p (get-buffer-process buffer))))
      (append record (list (cons 'terra-stale t)))
    record))

(defun terra-emacs-leaf-observe (buffer)
  "The leaf record BUFFER shows now, for comparing with a desired one."
  (terra-emacs-leaf-mark-stale
   (or (run-hook-with-args-until-success 'terra-emacs-leaf-capture-functions buffer)
       (buffer-local-value 'terra-emacs-leaf-record buffer)
       (terra-emacs-leaf--visit-record buffer))
   buffer))

;;;; Restoring

(defun terra-emacs-leaf--placeholder (record why)
  "A buffer saying RECORD could not come back, and WHY."
  (let ((buf (get-buffer-create (format "*terra-emacs: %s*" (car record)))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "terra-emacs could not restore %S:\n%s\n" (car record) why)))
      (special-mode)
      (setq terra-emacs-leaf-placeholder t))
    (message "terra-emacs: %s: %s" (car record) why)
    buf))

(defun terra-emacs-leaf-restore (record)
  "The buffer RECORD brings back (a placeholder when it cannot).
A buffer that really came back remembers RECORD, so a plan sees it
shows what was asked; a placeholder does not, so a plan retries it."
  (let ((file (terra-emacs-leaf-prop record 'filename)))
    (if (and file (not (file-remote-p file)) (not (file-exists-p file)))
        (terra-emacs-leaf--placeholder record (format "%s does not exist" file))
      (condition-case err
          (let ((buf (save-window-excursion
                       (save-current-buffer
                         (bookmark-handle-bookmark record)
                         (current-buffer)))))
            (unless (buffer-local-value 'terra-emacs-leaf-placeholder buf)
              (with-current-buffer buf
                (setq terra-emacs-leaf-record (terra-emacs-leaf-clean record))))
            buf)
        (error (terra-emacs-leaf--placeholder record (error-message-string err)))))))

(provide 'terra-emacs-leaf)
;;; terra-emacs-leaf.el ends here
