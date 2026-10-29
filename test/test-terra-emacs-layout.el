;;; test-terra-emacs-layout.el --- layouts: apply, read, compare; state files -*- lexical-binding: t; -*-

;;; Commentary:
;; Laying a hand-written tree out and reading it back (shown, and
;; hidden without showing it), leaves that restore through bookmark.el,
;; side windows left alone, and the state file's round trip.  No
;; capture package is loaded: the engine observes on its own.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs)

(defvar terra-emacs-test--dir nil)

(defun terra-emacs-test--file (name)
  "A file NAME in a fresh temp dir, created with some text."
  (let ((f (expand-file-name name (or terra-emacs-test--dir
                                      (setq terra-emacs-test--dir (terra-emacs-test-tmpdir))))))
    (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
    (with-temp-file f (insert "line one\nline two\nline three\n"))
    f))

(defun terra-emacs-test--leaf (file &rest props)
  "A layout leaf showing FILE, with node PROPS."
  (append (list :leaf (list (file-name-nondirectory file) (cons 'filename file))) props))

(defun terra-emacs-test--tree (a b)
  "File A left; file B over *scratch* right."
  (list :split 'right :sizes '(0.5 0.5)
        :children (list (terra-emacs-test--leaf a :selected t)
                        (list :split 'below :sizes '(0.5 0.5)
                              :children (list (terra-emacs-test--leaf b)
                                              (list :leaf (terra-emacs-leaf-make
                                                           "*scratch*" 'handler 'terra-emacs-leaf-buffer-handler
                                                           'buffer-name "*scratch*")))))))

(defun terra-emacs-test--keys (tree)
  "TREE's leaf keys."
  (mapcar #'terra-emacs-leaf-key (terra-emacs-layout-leaves tree)))

(ert-deftest terra-emacs-layout-apply-then-read ()
  (terra-emacs-test-reset-tabs)
  (let* ((a (terra-emacs-test--file "a.txt"))
         (b (terra-emacs-test--file "b.txt"))
         (tree (terra-emacs-test--tree a b)))
    (terra-emacs-layout-apply tree)
    (should (= 3 (length (window-list nil 'nomini))))
    (should (equal (buffer-file-name (window-buffer (selected-window))) a))
    (let ((have (terra-emacs-layout-current)))
      (should (terra-emacs-layout-same-p tree have))
      (should (equal (plist-get have :sizes) '(0.5 0.5)))
      (should (plist-get (car (plist-get have :children)) :selected))
      (should (equal (terra-emacs-test--keys have)
                     (list (list 'file a) (list 'file b) '(buffer "*scratch*")))))
    ;; A window showing something else is seen to differ.
    (switch-to-buffer "*Messages*")
    (should-not (terra-emacs-layout-same-p tree (terra-emacs-layout-current)))))

(ert-deftest terra-emacs-layout-reads-hidden-workspaces-without-showing-them ()
  (terra-emacs-test-reset-tabs)
  (let ((a (terra-emacs-test--file "a.txt"))
        (b (terra-emacs-test--file "b.txt"))
        (switches 0))
    (tab-bar-rename-tab "main")
    (find-file a)
    (terra-emacs-backend-create 'tab-bar "other")
    (terra-emacs-backend-with-workspace
     'tab-bar "other" (lambda () (terra-emacs-layout-apply (terra-emacs-test--tree a b))))
    (let ((count (lambda (&rest _) (cl-incf switches))))
      (advice-add 'tab-bar-select-tab :before count)
      (unwind-protect
          (should (equal (terra-emacs-test--keys (terra-emacs-layout-of 'tab-bar "other"))
                         (list (list 'file a) (list 'file b) '(buffer "*scratch*"))))
        (advice-remove 'tab-bar-select-tab count)))
    (should (= switches 0))))

(ert-deftest terra-emacs-layout-hidden-window-whose-buffer-died ()
  (terra-emacs-test-reset-tabs)
  (tab-bar-rename-tab "main")
  (terra-emacs-backend-create 'tab-bar "other")
  (terra-emacs-backend-with-workspace
   'tab-bar "other"
   (lambda ()
     ;; Laid out by hand: no window remembers a record.
     (delete-other-windows)
     (switch-to-buffer (get-buffer-create "*left*"))
     (set-window-buffer (split-window-right) (get-buffer-create "*right*"))))
  (kill-buffer "*right*")
  ;; Never a nil leaf: the window is left out, as showing it would.
  (let ((tree (terra-emacs-layout-of 'tab-bar "other")))
    (should (equal (terra-emacs-test--keys tree) '((buffer "*left*"))))
    (should (plist-member tree :leaf))))

(ert-deftest terra-emacs-layout-generic-leaves ()
  (let ((dir (terra-emacs-test-tmpdir)))
    ;; Dired restores through bookmark.el's default record (its directory).
    (let ((rec (list "dir" (cons 'filename dir))))
      (let ((buf (terra-emacs-leaf-restore rec)))
        (should (eq (buffer-local-value 'major-mode buf) 'dired-mode))
        (should (equal (terra-emacs-leaf-key (terra-emacs-leaf-observe buf)) (list 'file dir)))
        (kill-buffer buf)))
    ;; A missing file gives a placeholder, never a prompt.
    (let ((rec (list "gone" (cons 'filename (expand-file-name "missing.txt" dir)))))
      (should (string-match-p "terra-emacs" (buffer-name (terra-emacs-leaf-restore rec)))))
    ;; A plain buffer comes back by name.
    (let ((rec (terra-emacs-leaf-make "*plain*" 'handler 'terra-emacs-leaf-buffer-handler
                                      'buffer-name "*plain*")))
      (should (equal (buffer-name (terra-emacs-leaf-restore rec)) "*plain*"))
      (should (equal (terra-emacs-leaf-key (terra-emacs-leaf-observe (get-buffer "*plain*")))
                     '(buffer "*plain*"))))))

(ert-deftest terra-emacs-layout-leaves-side-windows-alone ()
  (terra-emacs-test-reset-tabs)
  (let* ((a (terra-emacs-test--file "a.txt"))
         (b (terra-emacs-test--file "b.txt"))
         (side (display-buffer-in-side-window (get-buffer-create "*side*") '((side . left))))
         (tree (list :split 'below :sizes '(0.5 0.5)
                     :children (list (terra-emacs-test--leaf a) (terra-emacs-test--leaf b)))))
    (unwind-protect
        (progn
          (terra-emacs-layout-apply tree)
          (should (window-live-p side))
          (should (terra-emacs-layout-same-p tree (terra-emacs-layout-current))))
      (when (window-live-p side) (delete-window side)))))

(ert-deftest terra-emacs-state-file-round-trip ()
  (let* ((a (terra-emacs-test--file "c.txt"))
         (file (expand-file-name "state.eld" (terra-emacs-test-tmpdir)))
         (state (list :terra-emacs 1 :backend 'tab-bar :current "main"
                      :workspaces (list (list :name "main" :id "id-main"
                                              :layout (list :leaf (list "c.txt" (cons 'filename a)
                                                                        (cons 'terra-stale t))))))))
    (terra-emacs-write-state state file)
    (should (equal (terra-emacs-read-state file) (terra-emacs-state-clean state)))
    (should-not (terra-emacs-layout-stale-p
                 (plist-get (car (plist-get (terra-emacs-read-state file) :workspaces)) :layout)))
    (with-temp-buffer
      (insert-file-contents file)
      (should (looking-at ";; terra-emacs state"))
      (should-not (re-search-forward "#<" nil t)))
    ;; Not a state, or a newer format: an error, never a guess.
    (with-temp-file file (insert "(:something 1)"))
    (should-error (terra-emacs-read-state file))
    (with-temp-file file (insert "(:terra-emacs 99)"))
    (should-error (terra-emacs-read-state file))))

(provide 'test-terra-emacs-layout)
;;; test-terra-emacs-layout.el ends here
