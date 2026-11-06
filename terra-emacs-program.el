;;; terra-emacs-program.el --- program leaves and a program registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A program leaf names a program and, optionally, what to run it with:
;;
;;   (NAME (handler . terra-emacs-program-handler) (program . PROGRAM)
;;         (args . LIST) (args-append . t) (env (VAR . VALUE) ...)
;;         (cwd . DIR) (config . PLIST) (input . STR-or-LIST)
;;         (buffer-name . STR))
;;
;; PROGRAM is a key of `terra-emacs-programs', the registry, whose entry
;; is a plist of defaults:
;;
;;   :command      the executable (a string), or a function of the
;;                 merged spec returning a string or a whole argv.
;;   :args         its arguments.
;;   :env          ((VAR . VALUE) ...); a nil VALUE unsets VAR.
;;   :cwd          where it runs.
;;   :config       a plist for :command and :launch functions.
;;   :buffer-name  default "*PROGRAM*".
;;
;; A leaf's keys override the entry's: args replace the entry's args
;; unless the leaf sets args-append, env and config merge per key with
;; the leaf winning.  A program the registry does not name runs as the
;; command PROGRAM.  `terra-emacs-define-program' adds an entry.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-leaf)

(defgroup terra-emacs-program nil
  "Program leaves in terra-emacs layouts."
  :group 'terra-emacs)

(defcustom terra-emacs-programs nil
  "The program registry: ((NAME . PLIST) ...), NAME a string.
PLIST holds a program's defaults: :command :args :env :cwd :config
:buffer-name; see terra-emacs-program.el.  A program leaf's own keys
override them."
  :type '(alist :key-type string :value-type plist))

(defun terra-emacs-define-program (name &rest plist)
  "Register program NAME with the defaults PLIST, replacing an entry.
See `terra-emacs-programs' for the keys.  Return NAME."
  (setf (alist-get name terra-emacs-programs nil nil #'equal) plist)
  name)

(defun terra-emacs-program-entry (name)
  "The registry plist of program NAME, or nil."
  (alist-get name terra-emacs-programs nil nil #'equal))

;;;; Merging

(defun terra-emacs-program--merge-alist (base over)
  "Alist BASE with OVER's entries replacing its own, by key."
  (append (cl-remove-if (lambda (p) (assoc (car p) over)) base)
          (copy-sequence over)))

(defun terra-emacs-program--merge-plist (base over)
  "Plist BASE with OVER's properties replacing its own."
  (let ((out (copy-sequence base)))
    (cl-loop for (k v) on over by #'cddr do (setq out (plist-put out k v)))
    out))

(defun terra-emacs-program--argv (command spec)
  "The argv COMMAND (a string or a function of SPEC) and SPEC's args make."
  (let ((cmd (if (functionp command) (funcall command spec) command)))
    (if (listp cmd) cmd (cons cmd (plist-get spec :args)))))

(defun terra-emacs-program-spec (record)
  "What the program leaf RECORD runs: its registry entry, overridden.
A plist of :program :argv :args :env :cwd :config :buffer-name, plus
the entry's other keys."
  (let* ((program (terra-emacs-leaf-prop record 'program))
         (entry (terra-emacs-program-entry program))
         (leaf (lambda (k) (assq k (cdr record))))
         (spec (copy-sequence entry)))
    (setq spec (plist-put spec :program program))
    (when (funcall leaf 'args)
      (setq spec (plist-put spec :args
                            (if (terra-emacs-leaf-prop record 'args-append)
                                (append (plist-get entry :args) (terra-emacs-leaf-prop record 'args))
                              (terra-emacs-leaf-prop record 'args)))))
    (setq spec (plist-put spec :env (terra-emacs-program--merge-alist
                                     (plist-get entry :env) (terra-emacs-leaf-prop record 'env))))
    (setq spec (plist-put spec :config (terra-emacs-program--merge-plist
                                        (plist-get entry :config)
                                        (terra-emacs-leaf-prop record 'config))))
    (dolist (k '(cwd buffer-name))
      (when (funcall leaf k)
        (setq spec (plist-put spec (intern (format ":%s" k)) (terra-emacs-leaf-prop record k)))))
    (unless (plist-get spec :buffer-name)
      (setq spec (plist-put spec :buffer-name (format "*%s*" program))))
    (plist-put spec :argv (terra-emacs-program--argv (or (plist-get entry :command) program) spec))))

(provide 'terra-emacs-program)
;;; terra-emacs-program.el ends here
