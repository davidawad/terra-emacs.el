;;; test-terra-emacs-plan.el --- piece 3: plan and apply -*- lexical-binding: t; -*-

;;; Commentary:
;; Diff a desired state against the live one, as data and in a buffer;
;; converge (create, rename, reorder, kill, level, layout); a dry run
;; changes nothing; a second apply plans nothing.  The round trip:
;; capture, kill every workspace, apply, capture again: equal.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-plan)
(require 'terra-emacs-persp)

(defun terra-emacs-test--files (&rest names)
  "Fresh files NAMES in one temp dir, as absolute paths."
  (let ((dir (terra-emacs-test-tmpdir)))
    (mapcar (lambda (n)
              (let ((f (expand-file-name n dir)))
                (with-temp-file f (insert n "\nsecond line\n"))
                f))
            names)))

(defun terra-emacs-test--leaf (file &rest props)
  "A layout leaf showing FILE, with node PROPS."
  (append (list :leaf (list (file-name-nondirectory file) (cons 'filename file))) props))

(defun terra-emacs-test--ops (plan)
  "PLAN's steps as (OP WS) pairs."
  (mapcar (lambda (s) (list (plist-get s :op) (plist-get s :ws))) plan))

(defun terra-emacs-test--fixture (a b c)
  "A desired state over files A, B and C."
  (list :terra-emacs 1
        :levels '((:id "ops" :name "Operations") (:id "home" :name "Home"))
        :current "code"
        :workspaces
        (list (list :name "code" :id "id-code" :level "ops"
                    :layout (list :split 'right :sizes '(0.5 0.5)
                                  :children (list (terra-emacs-test--leaf a :selected t)
                                                  (list :split 'below :sizes '(0.5 0.5)
                                                        :children (list (terra-emacs-test--leaf b)
                                                                        (terra-emacs-test--leaf c))))))
              (list :name "notes" :id "id-notes" :level "home"
                    :layout (terra-emacs-test--leaf c))
              (list :name "mail" :id "id-mail"))))

(ert-deftest terra-emacs-plan-dry-run-is-data-and-changes-nothing ()
  (terra-emacs-test-reset-tabs)
  (let* ((terra-emacs-levels nil)
         (files (terra-emacs-test--files "a.txt" "b.txt" "c.txt"))
         (state (apply #'terra-emacs-test--fixture files))
         (plan (terra-emacs-apply state t 'tab-bar)))
    (should (equal (terra-emacs-test--ops plan)
                   '((levels nil) (create "code") (create "notes") (create "mail")
                     (kill "*reset*") (level "code") (level "notes")
                     (layout "code") (layout "notes") (select "code"))))
    ;; Nothing changed.
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("*reset*")))
    (should-not terra-emacs-levels)
    ;; The plan buffer says the same in words.
    (terra-emacs-plan-show plan)
    (with-current-buffer "*terra-emacs-plan*"
      (should (string-match-p "create +code" (buffer-string)))
      (should (string-match-p "kill +\\*reset\\*" (buffer-string))))
    (should (equal (terra-emacs-plan state 'tab-bar) plan))))

(ert-deftest terra-emacs-apply-converges-then-plans-nothing ()
  (terra-emacs-test-reset-tabs)
  (let* ((terra-emacs-levels nil)
         (files (terra-emacs-test--files "a.txt" "b.txt" "c.txt"))
         (state (apply #'terra-emacs-test--fixture files)))
    (terra-emacs-apply state nil 'tab-bar)
    (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("code" "notes" "mail")))
    (should (equal (terra-emacs-backend-current 'tab-bar) "code"))
    (should (equal (terra-emacs-backend-level 'tab-bar "code") "ops"))
    (should (equal (terra-emacs-backend-id 'tab-bar "notes") "id-notes"))
    (should (equal terra-emacs-levels (plist-get state :levels)))
    (should (= 3 (length (window-list nil 'nomini))))
    (should (equal (buffer-file-name (window-buffer (selected-window))) (car files)))
    ;; Second apply: a no-op.
    (should-not (terra-emacs-apply state nil 'tab-bar))
    ;; Edits converge with the fewest steps: a rename (same id), a
    ;; move, and one layout rebuilt; the rest is untouched.
    (let* ((ws (plist-get state :workspaces))
           (edited (plist-put (copy-sequence state) :workspaces
                              (list (nth 2 ws)
                                    (plist-put (copy-sequence (nth 0 ws)) :name "src")
                                    (plist-put (copy-sequence (nth 1 ws)) :layout
                                               (terra-emacs-test--leaf (nth 1 files))))))
           (edited (plist-put edited :current "src"))
           (code-window (with-selected-window (selected-window) (selected-window))))
      (should (equal (terra-emacs-test--ops (terra-emacs-apply edited nil 'tab-bar))
                     '((rename "code") (move "mail") (layout "notes"))))
      (should (equal (terra-emacs-backend-workspaces 'tab-bar) '("mail" "src" "notes")))
      ;; The renamed workspace kept its windows (no rebuild).
      (should (window-live-p code-window))
      (should-not (terra-emacs-plan edited 'tab-bar)))))

(ert-deftest terra-emacs-apply-rebuilds-only-what-differs ()
  (terra-emacs-test-reset-tabs)
  (let* ((terra-emacs-levels nil)
         (files (terra-emacs-test--files "a.txt" "b.txt" "c.txt"))
         (state (apply #'terra-emacs-test--fixture files)))
    (terra-emacs-apply state nil 'tab-bar)
    ;; The user splits a window in "code": only "code" is rebuilt.
    (split-window-below)
    (should (equal (terra-emacs-test--ops (terra-emacs-plan state 'tab-bar))
                   '((layout "code"))))
    ;; A workspace the state does not name is killed.
    (terra-emacs-backend-create 'tab-bar "extra")
    (should (member '(kill "extra") (terra-emacs-test--ops (terra-emacs-apply state nil 'tab-bar))))
    (should-not (terra-emacs-plan state 'tab-bar))))

(defun terra-emacs-test--round-trip (backend)
  "Capture BACKEND's set, kill every workspace, apply, capture: equal."
  (let* ((files (terra-emacs-test--files "a.txt" "b.txt" "c.txt"))
         (state (apply #'terra-emacs-test--fixture files)))
    (terra-emacs-apply state nil backend)
    (let ((before (terra-emacs-state-clean (terra-emacs-capture-all backend))))
      ;; Each workspace's own windows were captured, not the shown one's.
      (should (equal (mapcar (lambda (w) (length (terra-emacs-layout-leaves (plist-get w :layout))))
                             (cl-remove-if-not (lambda (w) (member (plist-get w :name) '("code" "notes")))
                                               (plist-get before :workspaces)))
                     '(3 1)))
      (funcall (if (eq backend 'tab-bar) #'terra-emacs-test-reset-tabs #'terra-emacs-test-persp-on))
      (setq terra-emacs-levels nil)
      (should-not (member "code" (terra-emacs-backend-workspaces backend)))
      (terra-emacs-apply before nil backend)
      (should (equal (terra-emacs-state-clean (terra-emacs-capture-all backend)) before))
      (should-not (terra-emacs-plan before backend)))))

(ert-deftest terra-emacs-round-trip-tab-bar ()
  (terra-emacs-test-reset-tabs)
  (let ((terra-emacs-levels nil))
    (terra-emacs-test--round-trip 'tab-bar)))

(ert-deftest terra-emacs-round-trip-persp-mode ()
  (skip-unless (terra-emacs-test-have 'persp-mode))
  (terra-emacs-test-persp-on)
  (unwind-protect
      (let ((terra-emacs-levels nil))
        (terra-emacs-test--round-trip 'persp-mode))
    (terra-emacs-test-persp-off)))

(provide 'test-terra-emacs-plan)
;;; test-terra-emacs-plan.el ends here
