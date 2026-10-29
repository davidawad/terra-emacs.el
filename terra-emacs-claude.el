;;; terra-emacs-claude.el --- Claude Code sessions as layout leaves -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A Claude Code leaf is a record
;;
;;   (NAME (handler . terra-emacs-claude-bookmark-handler)
;;         (buffer-name . NAME) (session-id . ID) (cwd . DIR)
;;         (argv "claude" ...) (env (VAR . VALUE) ...))
;;
;; Restoring runs ARGV --resume SESSION-ID in eat, with the inherited
;; agent variables (`terra-emacs-claude-scrub-regexp': CLAUDE*,
;; CLAUDECODE, AGENT_*, ...) removed from the child's environment; a
;; claude that inherits them believes it is a sub-agent and does not save
;; its transcript.  Never two writers: when the session file shows the
;; session live, an Emacs eat buffer already running it is reused, and a
;; session live anywhere else opens `terra-emacs-claude-view-function'
;; (a read-only view) instead, saying so.
;;
;; The session files are read here only to keep to one writer; reading a
;; live session's id, argv and env into a record is the capture side, in
;; the terra-emacs-capture package.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'terra-emacs-leaf)
(require 'terra-emacs-handlers)

(defgroup terra-emacs-claude nil
  "Claude Code sessions in terra-emacs layouts."
  :group 'terra-emacs)

(defcustom terra-emacs-claude-sessions-directory
  (expand-file-name "~/.claude/sessions/")
  "Where Claude Code writes a <pid>.json record per running session."
  :type 'directory)

(defcustom terra-emacs-claude-program "claude"
  "The claude command, when a record has no argv of its own."
  :type 'string)

(defcustom terra-emacs-claude-scrub-regexp
  "\\`\\(CLAUDE[^=]*\\|AGENT_[^=]*\\|AWAD_[^=]*\\|LOADOUT_[^=]*\\|BD_ACTOR\\)\\(=\\|\\'\\)"
  "Inherited environment entries a restored claude must not see."
  :type 'regexp)

(defcustom terra-emacs-claude-resume-flags
  '(("--resume" . t) ("-r" . t) ("--session-id" . t) ("--continue" . nil) ("-c" . nil))
  "Flags dropped from a recorded argv before --resume: (FLAG . TAKES-A-VALUE)."
  :type '(alist :key-type string :value-type boolean))

(defcustom terra-emacs-claude-view-function #'terra-emacs-claude-view-default
  "Function of (SESSION-ID RECORD LIVE) returning a read-only view buffer.
Called for a session LIVE (its session file, a plist) outside this
Emacs's eat buffers."
  :type 'function)

(defvar-local terra-emacs-claude-session nil
  "The Claude session id this buffer runs.")
(put 'terra-emacs-claude-session 'permanent-local t)

(defvar-local terra-emacs-claude-env nil
  "The recorded environment ((NAME . VALUE) ...) this buffer's claude was given.")
(put 'terra-emacs-claude-env 'permanent-local t)

;;;; Session files

(defun terra-emacs-claude-pid-live-p (pid)
  "Non-nil when process PID exists."
  (and (integerp pid) (> pid 0)
       (or (process-attributes pid)
           ;; Some sandboxes hide process attributes; signal 0 still answers.
           (eql 0 (ignore-errors (signal-process pid 0))))
       t))

(defun terra-emacs-claude--ppid (pid)
  "The parent of process PID, or nil."
  (or (alist-get 'ppid (process-attributes pid))
      (let ((stat (format "/proc/%d/stat" pid)))
        (when (file-readable-p stat)
          (with-temp-buffer
            (ignore-errors (insert-file-contents-literally stat))
            ;; pid (comm) state ppid ...; comm may hold spaces.
            (when (re-search-forward ") [A-Za-z] \\([0-9]+\\)" nil t)
              (string-to-number (match-string 1))))))))

(defun terra-emacs-claude-sessions ()
  "Every session record (a plist with :pid :sessionId :cwd :status) on disk."
  (when (file-directory-p terra-emacs-claude-sessions-directory)
    (delq nil
          (mapcar (lambda (f)
                    (ignore-errors
                      (with-temp-buffer
                        (insert-file-contents f)
                        (json-parse-buffer :object-type 'plist :null-object nil
                                           :false-object nil))))
                  (directory-files terra-emacs-claude-sessions-directory t "\\`[0-9]+\\.json\\'")))))

(defun terra-emacs-claude-live-session (id)
  "The record of session ID when its process is alive, else nil."
  (cl-find-if (lambda (s) (and (equal (plist-get s :sessionId) id)
                               (terra-emacs-claude-pid-live-p (plist-get s :pid))))
              (terra-emacs-claude-sessions)))

(defun terra-emacs-claude-descends-p (pid ancestor)
  "Non-nil when PID is ANCESTOR or one of its descendants."
  (cl-loop repeat 64
           while (and (integerp pid) (> pid 1))
           thereis (= pid ancestor)
           do (setq pid (terra-emacs-claude--ppid pid))))

(defun terra-emacs-claude--eat-buffers ()
  "Eat buffers whose process runs."
  (cl-remove-if-not (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'eat-mode)
                                     (process-live-p (get-buffer-process b))))
                    (buffer-list)))

(defun terra-emacs-claude-buffer-of (pid)
  "The live eat buffer whose process is PID or an ancestor of it, or nil."
  (cl-find-if (lambda (b) (terra-emacs-claude-descends-p
                           pid (process-id (get-buffer-process b))))
              (terra-emacs-claude--eat-buffers)))

;;;; Restore

(defun terra-emacs-claude-strip-argv (argv)
  "ARGV without the flags of `terra-emacs-claude-resume-flags'."
  (let (out)
    (while argv
      (let* ((a (pop argv))
             (flag (assoc (car (split-string a "=")) terra-emacs-claude-resume-flags)))
        (cond ((not flag) (push a out))
              ((and (cdr flag) (not (string-search "=" a))) (pop argv)))))
    (nreverse out)))


(defun terra-emacs-claude-child-environment (env)
  "`process-environment' scrubbed of inherited agent variables, plus ENV."
  (append (mapcar (lambda (p) (concat (car p) "=" (cdr p))) env)
          (cl-remove-if (lambda (e) (string-match-p terra-emacs-claude-scrub-regexp e))
                        process-environment)))

(defun terra-emacs-claude-start (record)
  "Resume RECORD's session in eat; its buffer."
  (let* ((id (terra-emacs-leaf-prop record 'session-id))
         (env (terra-emacs-leaf-prop record 'env))
         (argv (append (or (terra-emacs-claude-strip-argv (terra-emacs-leaf-prop record 'argv))
                           (list terra-emacs-claude-program))
                       (list "--resume" id)))
         (buf (terra-emacs-eat-start (or (terra-emacs-leaf-prop record 'buffer-name)
                                         (format "*claude %s*" id))
                                     (terra-emacs-leaf-prop record 'cwd) argv
                                     (terra-emacs-claude-child-environment env))))
    (with-current-buffer buf
      (setq terra-emacs-claude-session id
            terra-emacs-claude-env env))
    buf))

(defun terra-emacs-claude-view-default (id record live)
  "A read-only buffer saying session ID (RECORD) is LIVE elsewhere."
  (let ((buf (get-buffer-create (format "*claude view %s*" id))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Claude session %s is live elsewhere (pid %s, %s, in %s).\n"
                        id (plist-get live :pid) (or (plist-get live :status) "status unknown")
                        (or (plist-get live :cwd) "?"))
                (format "terra-emacs did not resume it here: never two writers.\n")
                (format "Captured as %s.\n" (car record))))
      (special-mode))
    buf))

(defun terra-emacs-claude-bookmark-handler (record)
  "Make RECORD's Claude session current: reuse, view, or resume it."
  (let* ((id (terra-emacs-leaf-prop record 'session-id))
         (live (terra-emacs-claude-live-session id))
         (here (and live (terra-emacs-claude-buffer-of (plist-get live :pid)))))
    (set-buffer
     (cond (here here)
           (live
            (message "terra-emacs: Claude session %s is live elsewhere (pid %s); opened a read-only view"
                     id (plist-get live :pid))
            (let ((view (funcall terra-emacs-claude-view-function id record live)))
              ;; A view stands in for the session: a plan retries it.
              (with-current-buffer view (setq terra-emacs-leaf-placeholder t))
              view))
           (t (terra-emacs-claude-start record))))))

(put 'terra-emacs-claude-bookmark-handler 'terra-emacs-leaf-process t)
(put 'terra-emacs-claude-bookmark-handler 'terra-emacs-leaf-key-function
     (lambda (record) (list 'claude (terra-emacs-leaf-prop record 'session-id))))

(provide 'terra-emacs-claude)
;;; terra-emacs-claude.el ends here
