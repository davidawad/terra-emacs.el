;;; test-terra-emacs-autosave.el --- piece 5: restart = nothing changes -*- lexical-binding: t; -*-

;;; Commentary:
;; Named sets save and apply by name; autosave runs on `kill-emacs-hook'
;; and on a plain repeating timer (idle timers do not fire in neomacs);
;; nothing is autosaved over a state still waiting to be restored; and a
;; real restart (one child Emacs exits, the next starts) brings the same
;; workspaces back.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs)

(ert-deftest terra-emacs-autosave-named-sets ()
  (terra-emacs-test-reset-tabs)
  (let ((terra-emacs-directory (terra-emacs-test-tmpdir))
        (terra-emacs-backend 'tab-bar)
        (terra-emacs-levels nil))
    (tab-bar-rename-tab "work")
    (terra-emacs-backend-create 'tab-bar "mail")
    (let ((file (terra-emacs-save "work")))
      (should (equal file (terra-emacs-set-file "work")))
      (should (file-exists-p file))
      (should (member "work" (terra-emacs-sets))))
    (terra-emacs-test-reset-tabs)
    (should (terra-emacs-apply-set "work" t))
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("*reset*")))
    (terra-emacs-apply-set "work")
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("work" "mail")))
    (should-not (terra-emacs-apply-set "work"))))

(ert-deftest terra-emacs-autosave-mode-hooks-and-timer ()
  (let ((terra-emacs-autosave-interval 240)
        (terra-emacs-autosave-restore nil))
    (unwind-protect
        (progn
          (terra-emacs-autosave-mode 1)
          (should (memq #'terra-emacs-autosave-save kill-emacs-hook))
          (let ((timer (cl-find #'terra-emacs-autosave-save timer-list :key #'timer--function)))
            (should timer)
            (should (= (timer--repeat-delay timer) 240))
            (should-not (memq timer timer-idle-list)))
          (terra-emacs-autosave-mode -1)
          (should-not (memq #'terra-emacs-autosave-save kill-emacs-hook))
          (should-not (cl-find #'terra-emacs-autosave-save timer-list :key #'timer--function)))
      (terra-emacs-autosave-mode -1))))

(ert-deftest terra-emacs-autosave-never-clobbers-a-pending-restore ()
  (let* ((terra-emacs-directory (terra-emacs-test-tmpdir))
         (file (terra-emacs-set-file terra-emacs-autosave-name))
         (terra-emacs-autosave-restore t)
         (terra-emacs-autosave--restored nil))
    (make-directory terra-emacs-directory t)
    (with-temp-file file (insert "(:terra-emacs 1 :workspaces nil)"))
    (terra-emacs-autosave-save)
    (with-temp-buffer
      (insert-file-contents file)
      (should (equal (buffer-string) "(:terra-emacs 1 :workspaces nil)")))))

(defun terra-emacs-test--child (dir form)
  "Run FORM in a child batch Emacs with this package and DIR as its state dir.
Return its exit code; its output goes to *child*."
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (call-process emacs nil (get-buffer-create "*child*") nil
                  "-Q" "--batch" "-l" (expand-file-name "terra-emacs-test-helper.el" terra-emacs-test-dir)
                  "--eval"
                  (prin1-to-string
                   `(progn (require 'terra-emacs)
                           (setq terra-emacs-directory ,dir terra-emacs-backend 'tab-bar
                                 terra-emacs-autosave-interval 3600)
                           ,form)))))

(ert-deftest terra-emacs-autosave-restart-round-trip ()
  (let* ((dir (terra-emacs-test-tmpdir))
         (file (expand-file-name "notes.txt" dir))
         (capture (lambda (name)
                    `(with-temp-file ,(expand-file-name name dir)
                       (prin1 (terra-emacs-state-clean (terra-emacs-capture-all)) (current-buffer))))))
    (with-temp-file file (insert "notes\n"))
    ;; Emacs one: lay out two tabs, then exit; kill-emacs-hook autosaves.
    (should (= 0 (terra-emacs-test--child
                  dir `(progn (terra-emacs-autosave-mode 1)
                              (tab-bar-rename-tab "main")
                              (find-file ,file)
                              (split-window-right)
                              (terra-emacs-backend-create 'tab-bar "other")
                              (terra-emacs-backend-set-level 'tab-bar "other" "ops")
                              ,(funcall capture "before.eld")
                              (kill-emacs 0)))))
    (should (file-exists-p (expand-file-name "autosave.eld" dir)))
    ;; Emacs two: starting autosave mode restores the autosave.
    (should (= 0 (terra-emacs-test--child
                  dir `(progn (terra-emacs-autosave-mode 1)
                              ,(funcall capture "after.eld")))))
    (let ((read (lambda (n) (with-temp-buffer
                              (insert-file-contents (expand-file-name n dir))
                              (read (current-buffer))))))
      (should (equal (mapcar (lambda (w) (plist-get w :name))
                             (plist-get (funcall read "after.eld") :workspaces))
                     '("main" "other")))
      (should (equal (funcall read "after.eld") (funcall read "before.eld"))))))

(provide 'test-terra-emacs-autosave)
;;; test-terra-emacs-autosave.el ends here
