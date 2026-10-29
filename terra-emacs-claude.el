;;; terra-emacs-claude.el --- Claude Code sessions as layout leaves -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A Claude Code session running in an eat buffer captures as:
;;
;;   session-id  from ~/.claude/sessions/<pid>.json of the claude
;;               process (the eat process or one of its descendants).
;;   cwd, argv   the claude command line minus --resume, --session-id
;;               and --continue.
;;   env         the variables named by `terra-emacs-claude-env-regexp'
;;               it was given, never one matching
;;               `terra-emacs-claude-secret-regexp'.
;;
;; Restoring runs ARGV --resume SESSION-ID in eat, with the inherited
;; agent variables (`terra-emacs-claude-scrub-regexp': CLAUDE*,
;; CLAUDECODE, AGENT_*, ...) removed from the child's environment; a
;; claude that inherits them believes it is a sub-agent and does not save
;; its transcript.  Never two writers: when the session file shows the
;; session live, an Emacs eat buffer already running it is reused, and a
;; session live anywhere else opens `terra-emacs-claude-view-function'
;; (a read-only view) instead, saying so.

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
  "The claude command, when a capture finds no command line of its own."
  :type 'string)

(defcustom terra-emacs-claude-scrub-regexp
  "\\`\\(CLAUDE[^=]*\\|AGENT_[^=]*\\|AWAD_[^=]*\\|LOADOUT_[^=]*\\|BD_ACTOR\\)\\(=\\|\\'\\)"
  "Inherited environment entries a restored claude must not see."
  :type 'regexp)

(defcustom terra-emacs-claude-env-regexp
  "\\`\\(CLAUDE_CONFIG_DIR\\|ANTHROPIC_[A-Z0-9_]*\\|CLAUDE_CODE_[A-Z0-9_]*\\)\\'"
  "Names of the variables a capture records from a session's environment."
  :type 'regexp)

(defcustom terra-emacs-claude-secret-regexp "TOKEN\\|KEY\\|SECRET\\|PASSWORD"
  "Names matching this (any case) are never recorded."
  :type 'regexp)

(defcustom terra-emacs-claude-resume-flags
  '(("--resume" . t) ("-r" . t) ("--session-id" . t) ("--continue" . nil) ("-c" . nil))
  "Flags a capture drops from argv: (FLAG . TAKES-A-VALUE)."
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

(defun terra-emacs-claude--pid-live-p (pid)
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
                               (terra-emacs-claude--pid-live-p (plist-get s :pid))))
              (terra-emacs-claude-sessions)))

(defun terra-emacs-claude--descends-p (pid ancestor)
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
  (cl-find-if (lambda (b) (terra-emacs-claude--descends-p
                           pid (process-id (get-buffer-process b))))
              (terra-emacs-claude--eat-buffers)))

(defun terra-emacs-claude--session-in (buffer)
  "The live session record whose claude runs in BUFFER, or nil."
  (let ((proc (get-buffer-process buffer)))
    (and proc (process-live-p proc)
         (cl-find-if (lambda (s) (and (terra-emacs-claude--pid-live-p (plist-get s :pid))
                                      (terra-emacs-claude--descends-p (plist-get s :pid)
                                                                      (process-id proc))))
                     (terra-emacs-claude-sessions)))))

;;;; Capture

(defun terra-emacs-claude-strip-argv (argv)
  "ARGV without the flags of `terra-emacs-claude-resume-flags'."
  (let (out)
    (while argv
      (let* ((a (pop argv))
             (flag (assoc (car (split-string a "=")) terra-emacs-claude-resume-flags)))
        (cond ((not flag) (push a out))
              ((and (cdr flag) (not (string-search "=" a))) (pop argv)))))
    (nreverse out)))

(defun terra-emacs-claude--argv (buffer session)
  "The claude command line of BUFFER (whose live SESSION record may be nil)."
  (let ((argv (terra-emacs-eat-argv buffer)))
    (unless (and argv (string-match-p "claude" (file-name-nondirectory (car argv))))
      ;; eat runs a shell, or a wrapper: take claude's own arguments.
      (let* ((args (and session (alist-get 'args (process-attributes (plist-get session :pid)))))
             (words (and args (split-string args " " t))))
        (setq argv (or (cl-member-if (lambda (w) (string-match-p "claude" (file-name-nondirectory w)))
                                  words)
                       (list terra-emacs-claude-program)))))
    (terra-emacs-claude-strip-argv argv)))

(defun terra-emacs-claude--proc-env (pid)
  "PID's environment as (NAME . VALUE) pairs, where /proc shows it."
  (let ((file (format "/proc/%d/environ" pid)))
    (when (file-readable-p file)
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (ignore-errors (insert-file-contents-literally file))
        (delq nil (mapcar (lambda (e) (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" e)
                                        (cons (match-string 1 e) (match-string 2 e))))
                          (split-string (buffer-string) "\0" t)))))))

(defun terra-emacs-claude-recordable-env (pairs)
  "PAIRS ((NAME . VALUE) ...) a capture may record: needed, never secret."
  (let ((case-fold-search t))
    (cl-remove-if (lambda (p) (or (string-match-p terra-emacs-claude-secret-regexp (car p))
                                  (let ((case-fold-search nil))
                                    (not (string-match-p terra-emacs-claude-env-regexp (car p))))))
                  (cl-remove-duplicates pairs :key #'car :test #'equal :from-end t))))

(defun terra-emacs-claude-capture (buffer)
  "The leaf record of BUFFER when it is an eat buffer running Claude Code."
  (when (eq (buffer-local-value 'major-mode buffer) 'eat-mode)
    (let* ((session (terra-emacs-claude--session-in buffer))
           (id (or (plist-get session :sessionId)
                   (buffer-local-value 'terra-emacs-claude-session buffer))))
      (when id
        (with-current-buffer buffer
          (apply #'terra-emacs-leaf-make (buffer-name)
                 'handler 'terra-emacs-claude-bookmark-handler
                 'buffer-name (buffer-name) 'session-id id
                 'cwd (or (plist-get session :cwd) default-directory)
                 'argv (terra-emacs-claude--argv buffer session)
                 'env (terra-emacs-claude-recordable-env
                       (append terra-emacs-claude-env
                               (and session (terra-emacs-claude--proc-env (plist-get session :pid)))))
                 'terra-key (list 'claude id)
                 (unless (process-live-p (get-buffer-process buffer)) (list 'terra-stale t))))))))

;;;; Restore

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
            (funcall terra-emacs-claude-view-function id record live))
           (t (terra-emacs-claude-start record))))))

;; Before the generic eat handler: a Claude buffer is an eat buffer too.
(add-hook 'terra-emacs-leaf-capture-functions #'terra-emacs-claude-capture -50)

(provide 'terra-emacs-claude)
;;; terra-emacs-claude.el ends here
