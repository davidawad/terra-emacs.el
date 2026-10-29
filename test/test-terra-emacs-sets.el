;;; test-terra-emacs-sets.el --- named sets and applying one at start -*- lexical-binding: t; -*-

;;; Commentary:
;; A named set applies by name (dry run first); the start-up apply runs
;; once, and a real start (a child Emacs) converges on the autosave set
;; written by hand.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs)

(defun terra-emacs-test--write-set (dir name state)
  "Write STATE as the set NAME in DIR; its file."
  (let ((terra-emacs-directory dir))
    (terra-emacs-write-state state (terra-emacs-set-file name))))

(defconst terra-emacs-test--two
  '(:terra-emacs 1 :current "work"
    :workspaces ((:name "work" :id "id-work") (:name "mail" :id "id-mail" :level "ops")))
  "A set of two workspaces.")

(ert-deftest terra-emacs-sets-apply-by-name ()
  (terra-emacs-test-reset-tabs)
  (let ((terra-emacs-directory (terra-emacs-test-tmpdir))
        (terra-emacs-backend 'tab-bar)
        (terra-emacs-levels nil))
    (terra-emacs-test--write-set terra-emacs-directory "work" terra-emacs-test--two)
    (should (equal (terra-emacs-sets) '("work")))
    (should (terra-emacs-apply-set "work" t))
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("*reset*")))
    (terra-emacs-apply-set "work")
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("work" "mail")))
    (should (equal (terra-emacs-backend-level 'tab-bar "mail") "ops"))
    (should-not (terra-emacs-apply-set "work"))))

(ert-deftest terra-emacs-sets-restore-at-start-runs-once ()
  (terra-emacs-test-reset-tabs)
  (let* ((terra-emacs-directory (terra-emacs-test-tmpdir))
         (terra-emacs-backend 'tab-bar)
         (terra-emacs-levels nil)
         (terra-emacs-autosave--restored nil)
         (terra-emacs-autosave-restore t)
         (plans nil)
         (terra-emacs-autosave-after-restore-hook (list (lambda (p) (push p plans)))))
    (terra-emacs-test--write-set terra-emacs-directory terra-emacs-autosave-name terra-emacs-test--two)
    (terra-emacs-restore-at-start)
    (should terra-emacs-autosave--restored)
    (should (= 1 (length plans)))
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("work" "mail")))
    (terra-emacs-test-reset-tabs)
    ;; Once per Emacs: a second call does nothing.
    (terra-emacs-restore-at-start)
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("*reset*")))
    ;; `terra-emacs-restore-autosave' converges on demand.
    (terra-emacs-restore-autosave)
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("work" "mail")))))

(ert-deftest terra-emacs-sets-restore-off ()
  (let ((terra-emacs-autosave--restored nil)
        (terra-emacs-autosave-restore nil)
        (emacs-startup-hook nil))
    (terra-emacs-restore-at-start)
    (should-not terra-emacs-autosave--restored)
    (should-not emacs-startup-hook)))

(ert-deftest terra-emacs-sets-start-applies-in-a-fresh-emacs ()
  (let* ((dir (terra-emacs-test-tmpdir))
         (out (expand-file-name "after.eld" dir))
         (emacs (expand-file-name invocation-name invocation-directory)))
    (terra-emacs-test--write-set dir "autosave" terra-emacs-test--two)
    (should (= 0 (call-process
                  emacs nil (get-buffer-create "*child*") nil
                  "-Q" "--batch" "-l" (expand-file-name "terra-emacs-test-helper.el" terra-emacs-test-dir)
                  "--eval"
                  (prin1-to-string
                   `(progn (require 'terra-emacs)
                           (setq terra-emacs-directory ,dir terra-emacs-backend 'tab-bar)
                           (terra-emacs-restore-at-start)
                           (with-temp-file ,out
                             (prin1 (list (terra-emacs-backend-workspaces 'tab-bar)
                                          (terra-emacs-backend-current 'tab-bar)
                                          (terra-emacs-plan (terra-emacs-set-file "autosave")))
                                    (current-buffer))))))))
    (should (equal (with-temp-buffer (insert-file-contents out) (read (current-buffer)))
                   '(("work" "mail") "work" nil)))))

(provide 'test-terra-emacs-sets)
;;; test-terra-emacs-sets.el ends here
