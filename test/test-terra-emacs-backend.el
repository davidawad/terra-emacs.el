;;; test-terra-emacs-backend.el --- piece 1: workspace backends -*- lexical-binding: t; -*-

;;; Commentary:
;; The backend protocol against tab-bar and persp-mode: list, create,
;; rename, move, level, id, kill, and the levels a set declares.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-backend)
(require 'terra-emacs-persp)

(defun terra-emacs-test--exercise (b)
  "Run the protocol's contract against backend B (left with \"base\")."
  (should (terra-emacs-backend-available-p b))
  (terra-emacs-backend-create b "one")
  (terra-emacs-backend-create b "two")
  (terra-emacs-backend-create b "three")
  (should (equal (last (terra-emacs-backend-workspaces b) 3) '("one" "two" "three")))
  ;; Creating never shows the new workspace.
  (should (equal (terra-emacs-backend-current b) "base"))
  (terra-emacs-backend-rename b "two" "deux")
  (should (member "deux" (terra-emacs-backend-workspaces b)))
  (should-not (member "two" (terra-emacs-backend-workspaces b)))
  (terra-emacs-backend-move b "three" 0)
  (should (equal (car (terra-emacs-backend-workspaces b)) "three"))
  (terra-emacs-backend-move b "three" 3)
  (should (equal (terra-emacs-backend-workspaces b) '("base" "one" "deux" "three")))
  (terra-emacs-backend-set-level b "one" "ops")
  (should (equal (terra-emacs-backend-level b "one") "ops"))
  (should-not (terra-emacs-backend-level b "deux"))
  (terra-emacs-backend-set-level b "one" nil)
  (should-not (terra-emacs-backend-level b "one"))
  (terra-emacs-backend-set-id b "deux" "id-2")
  (should (equal (terra-emacs-backend-id b "deux") "id-2"))
  ;; The id follows a rename.
  (terra-emacs-backend-rename b "deux" "two")
  (should (equal (terra-emacs-backend-id b "two") "id-2"))
  (terra-emacs-backend-select b "one")
  (should (equal (terra-emacs-backend-current b) "one"))
  (should (equal (terra-emacs-backend-with-workspace b "three"
                   (lambda () (terra-emacs-backend-current b)))
                 "three"))
  (should (equal (terra-emacs-backend-current b) "one"))
  (terra-emacs-backend-kill b "three")
  ;; tab-bar keeps a group's tabs together, so a level change may move one.
  (should (equal (sort (terra-emacs-backend-workspaces b) #'string<) '("base" "one" "two"))))

(ert-deftest terra-emacs-backend-tab-bar-contract ()
  (terra-emacs-test-reset-tabs)
  (tab-bar-rename-tab "base")
  (terra-emacs-test--exercise 'tab-bar)
  ;; tab-bar levels are tab groups.
  (terra-emacs-backend-set-level 'tab-bar "two" "g1")
  (should (equal (alist-get 'group (nth 2 (funcall tab-bar-tabs-function))) "g1")))

(ert-deftest terra-emacs-backend-persp-contract ()
  (skip-unless (terra-emacs-test-have 'persp-mode))
  (terra-emacs-test-persp-on)
  (unwind-protect
      (progn
        (persp-add-new "base")
        (persp-switch "base")
        (terra-emacs-test--exercise 'persp-mode)
        ;; The level lives in the configured perspective parameter.
        (let ((terra-emacs-persp-level-parameter 'etm-level))
          (terra-emacs-backend-set-level 'persp-mode "two" 3)
          (should (equal (persp-parameter 'etm-level (persp-get-by-name "two")) 3))
          (should (equal (terra-emacs-backend-level 'persp-mode "two") 3)))
        ;; An order parameter, when configured, follows moves.
        (let ((terra-emacs-persp-order-parameter 'etm-tab-order))
          (terra-emacs-backend-move 'persp-mode "two" 0)
          (should (equal (terra-emacs-backend-workspaces 'persp-mode) '("two" "base" "one")))
          (should (equal (persp-parameter 'etm-tab-order (persp-get-by-name "one")) 2))))
    (terra-emacs-test-persp-off)))

(ert-deftest terra-emacs-backend-levels-and-choice ()
  (let ((terra-emacs-levels nil))
    (terra-emacs-backend-set-levels 'tab-bar '((:id "ops" :name "Operations")))
    (should (equal (terra-emacs-backend-levels 'tab-bar) '((:id "ops" :name "Operations"))))
    (let ((seen nil))
      (let ((terra-emacs-levels-functions (list (lambda (l) (setq seen l)))))
        (terra-emacs-backend-set-levels 'tab-bar '((:id 1 :name "One"))))
      (should (equal seen '((:id 1 :name "One"))))))
  (let ((terra-emacs-backend nil) (terra-emacs-backend-candidates '(persp-mode tab-bar)))
    (when (bound-and-true-p persp-mode) (persp-mode -1))
    (should (eq (terra-emacs-current-backend) 'tab-bar)))
  (let ((terra-emacs-backend 'tab-bar))
    (should (eq (terra-emacs-current-backend) 'tab-bar))))

(provide 'test-terra-emacs-backend)
;;; test-terra-emacs-backend.el ends here
