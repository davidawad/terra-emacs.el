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
;;   :launch       a function of the merged spec returning the buffer
;;                 it starts, in place of a terminal running the argv.
;;   :process      nil for a :launch program whose buffer runs no
;;                 process (default t: a dead process is stale).
;;
;; A leaf's keys override the entry's: args replace the entry's args
;; unless the leaf sets args-append, env and config merge per key with
;; the leaf winning.  A program the registry does not name runs as the
;; command PROGRAM.  `terra-emacs-define-program' adds an entry.
;;
;; The argv runs in a terminal (`terra-emacs-program-terminal-function',
;; default eat).  Restoring reuses the buffer when its process runs the
;; same spec; a program buffer whose argv, env or config changed is
;; restarted.
;;
;; A program buffer captures back to the leaf it was started from
;; (program, args, env, cwd, config, ...), so save and restore
;; round-trip exactly: `terra-emacs-program-capture' sits on
;; `terra-emacs-leaf-capture-functions' ahead of any generic terminal
;; capture.  Its argv, env and config are part of a leaf's identity, so
;; a plan rebuilds a layout whose program runs something else (:why
;; differs), and the rebuild restarts it.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-leaf)
(require 'terra-emacs-handlers)

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

;;;; Launching

(defcustom terra-emacs-program-terminal-function #'terra-emacs-eat-start
  "Function of (NAME DIR ARGV ENVIRONMENT) returning a terminal buffer.
It runs ARGV in the buffer NAME in DIR with the `process-environment'
ENVIRONMENT, reusing a buffer NAME whose live process already runs ARGV."
  :type 'function)

(defvar-local terra-emacs-program-live nil
  "The spec (`terra-emacs-program-spec') this buffer's program was started with.")
(put 'terra-emacs-program-live 'permanent-local t)

(defun terra-emacs-program--identity (spec)
  "What of SPEC tells two runs of a program apart: argv, env, config."
  (list (plist-get spec :argv) (plist-get spec :env) (plist-get spec :config)))

(defun terra-emacs-program--environment (env)
  "`process-environment' with ENV's entries first; a nil value unsets."
  (append (mapcar (lambda (p) (if (cdr p) (concat (car p) "=" (cdr p)) (car p))) env)
          process-environment))

(defun terra-emacs-program--process-p (spec)
  "Non-nil when SPEC's buffer runs a process."
  (if (plist-member spec :process) (plist-get spec :process) t))

(defun terra-emacs-program--reusable-p (buffer spec)
  "Non-nil when BUFFER already runs SPEC (or one it cannot identify)."
  (let ((have (buffer-local-value 'terra-emacs-program-live buffer)))
    (and (or (not (terra-emacs-program--process-p spec))
             (terra-emacs-handlers--live-p buffer))
         (or (null have)
             (equal (terra-emacs-program--identity have) (terra-emacs-program--identity spec))))))

(defun terra-emacs-program-start (spec)
  "The buffer running SPEC: a live one reused, else a new start."
  (let* ((name (plist-get spec :buffer-name))
         (old (get-buffer name))
         (dir (terra-emacs-handlers--dir (plist-get spec :cwd))))
    (if (and old (terra-emacs-program--reusable-p old spec))
        old
      ;; Ours, running something else: stop it so it starts afresh.
      (when (and old (buffer-local-value 'terra-emacs-program-live old))
        (terra-emacs-handlers--stop old))
      (let ((buf (if (plist-get spec :launch)
                     (let ((default-directory dir))
                       (save-window-excursion
                         (save-current-buffer
                           (let ((b (funcall (plist-get spec :launch) spec)))
                             (if (bufferp b) b (current-buffer))))))
                   (funcall terra-emacs-program-terminal-function name dir (plist-get spec :argv)
                            (terra-emacs-program--environment (plist-get spec :env))))))
        (with-current-buffer buf (setq terra-emacs-program-live spec))
        buf))))

(defvar-local terra-emacs-program-leaf nil
  "The program leaf this buffer was started from, as written.")
(put 'terra-emacs-program-leaf 'permanent-local t)

(defun terra-emacs-program-handler (record)
  "Make the program leaf RECORD's buffer current, starting it when not running."
  (let ((buf (terra-emacs-program-start (terra-emacs-program-spec record))))
    (with-current-buffer buf
      (setq terra-emacs-program-leaf (terra-emacs-leaf-clean record)))
    (set-buffer buf)))

(put 'terra-emacs-program-handler 'terra-emacs-leaf-process
     (lambda (record) (terra-emacs-program--process-p (terra-emacs-program-spec record))))
(defun terra-emacs-program-leaf-key (record)
  "The identity of the program leaf RECORD: buffer, program, argv, env, config.
An observed leaf's `terra-live' (what runs) stands in for the merge, so
a leaf whose args, env or config differ from the live process, or whose
registry entry changed, plans a rebuild."
  (let ((spec (terra-emacs-program-spec record)))
    (list 'program (plist-get spec :buffer-name) (plist-get spec :program)
          (if (assq 'terra-live (cdr record))
              (terra-emacs-leaf-prop record 'terra-live)
            (terra-emacs-program--identity spec)))))

(put 'terra-emacs-program-handler 'terra-emacs-leaf-key-function #'terra-emacs-program-leaf-key)

;;;; Capture

(defun terra-emacs-program-capture (buffer)
  "The program leaf BUFFER was started from, or nil when it was not.
The record is the leaf as written, plus `terra-live': the argv, env
and config the buffer's program really runs, for a plan to compare."
  (let ((leaf (buffer-local-value 'terra-emacs-program-leaf buffer))
        (live (buffer-local-value 'terra-emacs-program-live buffer)))
    (when leaf
      (append (copy-sequence leaf)
              (list (cons 'terra-live (terra-emacs-program--identity live)))))))

;; Ahead of terminal captures: a program buffer is an eat buffer too.
(add-hook 'terra-emacs-leaf-capture-functions #'terra-emacs-program-capture -90)

(provide 'terra-emacs-program)
;;; terra-emacs-program.el ends here
