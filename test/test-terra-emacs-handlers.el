;;; test-terra-emacs-handlers.el --- piece 4: eshell, eat, vterm -*- lexical-binding: t; -*-

;;; Commentary:
;; Each handler captures cwd and command, restores them, reuses a live
;; buffer instead of starting a second process, and marks a leaf whose
;; process died stale so a plan restarts it.  vterm needs a compiled
;; module, so a stand-in defining the slice the handler uses runs here.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-handlers)
(require 'terra-emacs-plan)

(defun terra-emacs-test--wait-file (file)
  "Wait up to 5s for FILE to hold text; its contents."
  (cl-loop repeat 100
           until (and (file-exists-p file)
                      (> (file-attribute-size (file-attributes file)) 0))
           do (accept-process-output nil 0.05))
  (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string))))

(defun terra-emacs-test--kill (buffer)
  "Kill BUFFER and its process quietly."
  (when (buffer-live-p buffer)
    (let ((p (get-buffer-process buffer)))
      (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))

(ert-deftest terra-emacs-handlers-eshell ()
  (require 'eshell)
  (let* ((dir (terra-emacs-test-tmpdir))
         (rec (terra-emacs-leaf-make "*eshell*<work>" 'handler 'terra-emacs-eshell-bookmark-handler
                                     'terra-key '(eshell "*eshell*<work>")
                                     'buffer-name "*eshell*<work>" 'cwd dir))
         (buf (terra-emacs-leaf-restore rec)))
    (unwind-protect
        (progn
          (should (equal (buffer-name buf) "*eshell*<work>"))
          (should (eq (buffer-local-value 'major-mode buf) 'eshell-mode))
          (should (equal (buffer-local-value 'default-directory buf) dir))
          (let ((again (terra-emacs-leaf-capture buf)))
            (should (equal (terra-emacs-leaf-key again) (terra-emacs-leaf-key rec)))
            (should (equal (terra-emacs-leaf-prop again 'cwd) dir)))
          (should (eq (terra-emacs-leaf-restore rec) buf)))
      (terra-emacs-test--kill buf))))

(ert-deftest terra-emacs-handlers-eat ()
  (skip-unless (terra-emacs-test-have 'eat))
  (let* ((dir (terra-emacs-test-tmpdir))
         (argv (list "/bin/sh" "-c" "pwd > where; echo $$ >> where; sleep 30"))
         (rec (terra-emacs-leaf-make "*shell-work*" 'handler 'terra-emacs-eat-bookmark-handler
                                     'buffer-name "*shell-work*" 'cwd dir 'argv argv
                                     'terra-key (list 'eat "*shell-work*" argv)))
         (buf (terra-emacs-leaf-restore rec)))
    (unwind-protect
        (let ((pid (process-id (get-buffer-process buf))))
          (should (eq (buffer-local-value 'major-mode buf) 'eat-mode))
          (should (string-prefix-p (directory-file-name (file-truename dir))
                                   (terra-emacs-test--wait-file (expand-file-name "where" dir))))
          ;; The capture is the record: cwd, the command, the same key.
          (let ((cap (terra-emacs-leaf-capture buf)))
            (should (equal (terra-emacs-leaf-prop cap 'argv) argv))
            (should (equal (terra-emacs-leaf-key cap) (terra-emacs-leaf-key rec)))
            (should-not (terra-emacs-leaf-stale-p cap)))
          ;; eat gains bookmark support.
          (should (equal (terra-emacs-leaf-prop (with-current-buffer buf (bookmark-make-record)) 'argv)
                         argv))
          ;; A second restore reuses the live process.
          (should (eq (terra-emacs-leaf-restore rec) buf))
          (should (= pid (process-id (get-buffer-process buf))))
          ;; Its process gone, the leaf is stale and a plan restarts it.
          (terra-emacs-test-reset-tabs)
          (let ((state (list :terra-emacs 1
                             :workspaces (list (list :name "*reset*" :layout (list :leaf rec))))))
            (terra-emacs-apply state nil 'tab-bar)
            (should-not (terra-emacs-plan state 'tab-bar))
            (delete-process (get-buffer-process buf))
            (should (terra-emacs-leaf-stale-p (terra-emacs-leaf-capture buf)))
            (should (equal (mapcar (lambda (s) (plist-get s :why)) (terra-emacs-plan state 'tab-bar))
                           '(stale)))
            (terra-emacs-apply state nil 'tab-bar)
            (should (process-live-p (get-buffer-process (get-buffer "*shell-work*"))))
            (should-not (= pid (process-id (get-buffer-process (get-buffer "*shell-work*")))))
            (should-not (terra-emacs-plan state 'tab-bar))))
      (terra-emacs-test--kill (get-buffer "*shell-work*")))))

;;;; A vterm stand-in: the slice of vterm the handler uses.

(defvar vterm-shell)
(unless (featurep 'vterm)
  (defvar vterm-shell "/bin/sh")
  (define-derived-mode vterm-mode fundamental-mode "VTerm"
    "Stand-in vterm: runs `vterm-shell' in the buffer, through sh as vterm does."
    (make-process :name "vterm" :buffer (current-buffer) :noquery t
                  :command (list "/bin/sh" "-c" (concat "exec " vterm-shell))))
  (provide 'vterm))

(ert-deftest terra-emacs-handlers-vterm ()
  (let* ((dir (terra-emacs-test-tmpdir))
         (cmd "sh -c 'pwd > where; sleep 30'")
         (rec (terra-emacs-leaf-make "*vterm work*" 'handler 'terra-emacs-vterm-bookmark-handler
                                     'buffer-name "*vterm work*" 'cwd dir 'command cmd
                                     'terra-key (list 'vterm "*vterm work*" cmd)))
         (buf (terra-emacs-leaf-restore rec)))
    (unwind-protect
        (progn
          (should (eq (buffer-local-value 'major-mode buf) 'vterm-mode))
          (should (equal (terra-emacs-test--wait-file (expand-file-name "where" dir))
                         (directory-file-name (file-truename dir))))
          (let ((cap (terra-emacs-leaf-capture buf)))
            (should (equal (terra-emacs-leaf-prop cap 'command) cmd))
            (should (equal (terra-emacs-leaf-key cap) (terra-emacs-leaf-key rec))))
          (should (eq (terra-emacs-leaf-restore rec) buf)))
      (terra-emacs-test--kill buf))))

(provide 'test-terra-emacs-handlers)
;;; test-terra-emacs-handlers.el ends here
