;;; test-terra-emacs-claude.el --- restoring Claude Code sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; Fake ~/.claude/sessions records (idle, busy, elsewhere, dead) and a
;; fake claude that records its argv and environment and then writes
;; its own session record, as the real one does.  Resume with a clean
;; env, reuse a live buffer, never a second writer.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-claude)

(defvar terra-emacs-test--sessions nil "The fake sessions directory.")
(defvar terra-emacs-test--out nil "Where the fake claude writes argv and env.")

(defun terra-emacs-test--fake-claude ()
  "A fake claude in a fresh dir; its path."
  (let* ((dir (terra-emacs-test-tmpdir))
         (bin (expand-file-name "claude" dir)))
    (with-temp-file bin
      (insert "#!/bin/sh\n"
              "out=\"$TERRA_FAKE_OUT\"; sid=none; prev=\n"
              "for a in \"$@\"; do echo \"$a\" >> \"$out/argv.tmp\";"
              " [ \"$prev\" = --resume ] && sid=\"$a\"; prev=\"$a\"; done\n"
              "env > \"$out/env\"\n"
              "printf '{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"%s\",\"status\":\"idle\"}'"
              " $$ \"$sid\" \"$PWD\" > \"$TERRA_FAKE_SESSIONS/$$.json\"\n"
              "mv \"$out/argv.tmp\" \"$out/argv\"\n"
              "sleep 30\n"))
    (set-file-modes bin #o755)
    bin))

(defun terra-emacs-test--lines (file)
  "FILE's lines, after waiting up to 5s for it."
  (cl-loop repeat 100 until (file-exists-p file) do (accept-process-output nil 0.05))
  (with-temp-buffer (insert-file-contents file) (split-string (buffer-string) "\n" t)))

(defun terra-emacs-test--session-file (pid id status)
  "Write a session record for PID running session ID with STATUS."
  (with-temp-file (expand-file-name (format "%d.json" pid) terra-emacs-test--sessions)
    (insert (format "{\"pid\":%d,\"sessionId\":\"%s\",\"cwd\":\"/tmp\",\"status\":\"%s\"}"
                    pid id status))))

(defmacro terra-emacs-test--with-claude (&rest body)
  "Run BODY with fake sessions, a fake claude and an inherited agent env."
  (declare (indent 0))
  `(let* ((terra-emacs-test--sessions (terra-emacs-test-tmpdir))
          (terra-emacs-test--out (terra-emacs-test-tmpdir))
          (terra-emacs-claude-sessions-directory terra-emacs-test--sessions)
          (process-environment
           (append (list (concat "TERRA_FAKE_OUT=" terra-emacs-test--out)
                         (concat "TERRA_FAKE_SESSIONS=" terra-emacs-test--sessions)
                         "CLAUDECODE=1" "CLAUDE_CODE_ENTRYPOINT=cli" "AGENT_NAME=pm"
                         "AWAD_ROLE=x" "LOADOUT_ID=y" "BD_ACTOR=z")
                   process-environment))
          (fake (terra-emacs-test--fake-claude))
          (buffers nil))
     (unwind-protect (progn ,@body)
       (dolist (b (buffer-list))
         (when (string-prefix-p "*claude" (buffer-name b))
           (let ((p (get-buffer-process b)))
             (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))))

(defun terra-emacs-test--record (fake id)
  "A captured Claude leaf running FAKE for session ID."
  (terra-emacs-leaf-make (format "*claude %s*" id)
                         'handler 'terra-emacs-claude-bookmark-handler
                         'buffer-name (format "*claude %s*" id)
                         'session-id id 'cwd temporary-file-directory
                         'argv (list fake "--model" "opus" "--resume" "older" "--continue")
                         'env '(("CLAUDE_CONFIG_DIR" . "/tmp/claude-config"))))

(ert-deftest terra-emacs-claude-resumes-with-a-clean-env ()
  (skip-unless (terra-emacs-test-have 'eat))
  (terra-emacs-test--with-claude
    (let ((buf (terra-emacs-leaf-restore (terra-emacs-test--record fake "sess-1"))))
      (should (eq (buffer-local-value 'major-mode buf) 'eat-mode))
      ;; argv minus the old resume flags, plus --resume <id>.
      (should (equal (terra-emacs-test--lines (expand-file-name "argv" terra-emacs-test--out))
                     '("--model" "opus" "--resume" "sess-1")))
      (let ((env (terra-emacs-test--lines (expand-file-name "env" terra-emacs-test--out))))
        (dolist (gone '("CLAUDECODE=" "CLAUDE_CODE_ENTRYPOINT=" "AGENT_NAME=" "AWAD_ROLE="
                        "LOADOUT_ID=" "BD_ACTOR="))
          (should-not (cl-find-if (lambda (l) (string-prefix-p gone l)) env)))
        (should (member "CLAUDE_CONFIG_DIR=/tmp/claude-config" env)))
      (should (equal (buffer-local-value 'terra-emacs-claude-session buf) "sess-1")))))

(ert-deftest terra-emacs-claude-reuses-its-live-buffer ()
  (skip-unless (terra-emacs-test-have 'eat))
  (terra-emacs-test--with-claude
    (let* ((rec (terra-emacs-test--record fake "sess-1"))
           (buf (terra-emacs-leaf-restore rec)))
      (terra-emacs-test--lines (expand-file-name "argv" terra-emacs-test--out))
      (let ((pid (process-id (get-buffer-process buf))))
        ;; The fake wrote ~/.claude/sessions/<pid>.json: live, in Emacs.
        (should (equal (plist-get (terra-emacs-claude-live-session "sess-1") :pid) pid))
        (should (eq (terra-emacs-leaf-restore rec) buf))
        (should (= pid (process-id (get-buffer-process buf))))
        ;; Observed: the session it was restored from.
        (should (equal (terra-emacs-leaf-key (terra-emacs-leaf-observe buf)) '(claude "sess-1")))
        (should (equal (terra-emacs-claude-buffer-of pid) buf))))))

(ert-deftest terra-emacs-claude-live-elsewhere-opens-a-view ()
  (terra-emacs-test--with-claude
    (dolist (status '("idle" "busy"))
      (let* ((other (make-process :name "elsewhere" :command '("sleep" "30") :noquery t))
             (id (concat "sess-" status))
             (seen nil)
             (terra-emacs-claude-view-function
              (lambda (sid rec live)
                (setq seen (list sid (car rec) (plist-get live :status)))
                (terra-emacs-claude-view-default sid rec live))))
        (unwind-protect
            (progn
              (terra-emacs-test--session-file (process-id other) id status)
              (let ((buf (terra-emacs-leaf-restore (terra-emacs-test--record fake id))))
                (should (equal seen (list id (format "*claude %s*" id) status)))
                (should (buffer-local-value 'buffer-read-only buf))
                ;; A view is a stand-in: a plan retries the session later.
                (should (buffer-local-value 'terra-emacs-leaf-placeholder buf))
                (should (string-match-p "live elsewhere" (with-current-buffer buf (buffer-string))))
                ;; Never a second writer: the fake never ran.
                (should-not (file-exists-p (expand-file-name "argv" terra-emacs-test--out)))))
          (delete-process other))))))

(ert-deftest terra-emacs-claude-dead-record-resumes ()
  (skip-unless (terra-emacs-test-have 'eat))
  (terra-emacs-test--with-claude
    (let ((dead (make-process :name "dead" :command '("true"))))
      (cl-loop repeat 100 while (process-live-p dead) do (accept-process-output nil 0.05))
      (terra-emacs-test--session-file (process-id dead) "sess-old" "busy")
      (should-not (terra-emacs-claude-live-session "sess-old"))
      (terra-emacs-leaf-restore (terra-emacs-test--record fake "sess-old"))
      (should (member "sess-old" (terra-emacs-test--lines
                                  (expand-file-name "argv" terra-emacs-test--out)))))))

(provide 'test-terra-emacs-claude)
;;; test-terra-emacs-claude.el ends here
