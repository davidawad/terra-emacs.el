;;; test-terra-emacs-capture.el --- piece 2: capture -*- lexical-binding: t; -*-

;;; Commentary:
;; Capturing a workspace (split tree plus leaf records) and the whole
;; set (levels, every workspace with name, level, order), laying a
;; captured tree back out, and the state file's round trip.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-capture)

(defvar terra-emacs-test--dir nil)

(defun terra-emacs-test--file (name)
  "A file NAME in a fresh temp dir, created with some text."
  (let ((f (expand-file-name name (or terra-emacs-test--dir
                                      (setq terra-emacs-test--dir (terra-emacs-test-tmpdir))))))
    ;; A buffer still visiting it would make `find-file' ask about the change.
    (when (get-file-buffer f) (kill-buffer (get-file-buffer f)))
    (with-temp-file f (insert "line one\nline two\nline three\n"))
    f))

(defun terra-emacs-test--split-layout (a b)
  "Lay out the selected frame: file A left, file B and *scratch* right."
  (delete-other-windows)
  (find-file a)
  (let ((right (split-window-right)))
    (with-selected-window right
      (find-file b)
      (goto-char (point-min)) (forward-line 1)
      (split-window-below)
      (other-window 1)
      (switch-to-buffer "*scratch*"))))

(ert-deftest terra-emacs-capture-workspace-tree ()
  (terra-emacs-test-reset-tabs)
  (let ((a (terra-emacs-test--file "a.txt"))
        (b (terra-emacs-test--file "b.txt")))
    (terra-emacs-test--split-layout a b)
    (let* ((ws (terra-emacs-capture "*reset*" 'tab-bar))
           (tree (plist-get ws :layout)))
      (should (equal (plist-get ws :name) "*reset*"))
      (should (stringp (plist-get ws :id)))
      (should (eq (plist-get tree :split) 'right))
      (should (equal (plist-get tree :sizes) '(0.5 0.5)))
      (let ((left (nth 0 (plist-get tree :children)))
            (right (nth 1 (plist-get tree :children))))
        (should (equal (terra-emacs-leaf-key (plist-get left :leaf)) (list 'file a)))
        (should (plist-get left :selected))
        (should (eq (plist-get right :split) 'below))
        (should (equal (mapcar (lambda (c) (terra-emacs-leaf-key (plist-get c :leaf)))
                               (plist-get right :children))
                       (list (list 'file b) '(buffer "*scratch*")))))
      ;; Laying the tree out again in a bare frame gives the same tree.
      (delete-other-windows)
      (switch-to-buffer "*Messages*")
      (kill-buffer (get-file-buffer b))
      (terra-emacs-layout-apply tree)
      (should (= 3 (length (window-list nil 'nomini))))
      (should (equal (buffer-file-name (window-buffer (selected-window))) a))
      (should (terra-emacs-layout-same-p tree (terra-emacs-layout-capture))))))

(ert-deftest terra-emacs-capture-all-set ()
  (terra-emacs-test-reset-tabs)
  (let ((terra-emacs-levels '((:id "ops" :name "Operations"))))
    (tab-bar-rename-tab "main")
    (terra-emacs-backend-create 'tab-bar "mail")
    (terra-emacs-backend-create 'tab-bar "notes")
    (terra-emacs-backend-set-level 'tab-bar "mail" "ops")
    (terra-emacs-backend-set-level 'tab-bar "notes" "home")
    (let ((state (terra-emacs-capture-all 'tab-bar)))
      (should (equal (plist-get state :terra-emacs) terra-emacs-format-version))
      (should (eq (plist-get state :backend) 'tab-bar))
      (should (equal (plist-get state :current) "main"))
      (should (equal (mapcar (lambda (w) (plist-get w :name)) (plist-get state :workspaces))
                     '("main" "mail" "notes")))
      (should (equal (mapcar (lambda (w) (plist-get w :level)) (plist-get state :workspaces))
                     '(nil "ops" "home")))
      ;; A level a workspace uses but no declaration names is declared.
      (should (equal (plist-get state :levels)
                     '((:id "ops" :name "Operations") (:id "home" :name "home"))))
      ;; Capturing did not change what is shown.
      (should (equal (terra-emacs-backend-current 'tab-bar) "main"))
      ;; Ids are stable: a second capture reports the same ones.
      (should (equal (mapcar (lambda (w) (plist-get w :id)) (plist-get state :workspaces))
                     (mapcar (lambda (w) (plist-get w :id))
                             (plist-get (terra-emacs-capture-all 'tab-bar) :workspaces)))))))

(ert-deftest terra-emacs-capture-reads-hidden-workspaces-without-showing-them ()
  (terra-emacs-test-reset-tabs)
  (let ((a (terra-emacs-test--file "a.txt"))
        (b (terra-emacs-test--file "b.txt"))
        (switches 0))
    (tab-bar-rename-tab "main")
    (find-file a)
    (terra-emacs-backend-create 'tab-bar "other")
    (terra-emacs-backend-with-workspace 'tab-bar "other"
                                        (lambda () (terra-emacs-test--split-layout a b)))
    (let ((count (lambda (&rest _) (cl-incf switches))))
      (advice-add 'tab-bar-select-tab :before count)
      (unwind-protect
          (let ((other (terra-emacs-capture "other" 'tab-bar)))
            (should (= switches 0))
            (should (equal (mapcar #'terra-emacs-leaf-key
                                   (terra-emacs-layout-leaves (plist-get other :layout)))
                           (list (list 'file a) (list 'file b) '(buffer "*scratch*")))))
        (advice-remove 'tab-bar-select-tab count)))))

(ert-deftest terra-emacs-capture-state-file-round-trip ()
  (terra-emacs-test-reset-tabs)
  (let* ((a (terra-emacs-test--file "c.txt"))
         (file (expand-file-name "state.eld" (terra-emacs-test-tmpdir))))
    (find-file a)
    (let ((state (terra-emacs-capture-all 'tab-bar)))
      (terra-emacs-write-state state file)
      (should (equal (terra-emacs-read-state file) (terra-emacs-state-clean state)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (looking-at ";; terra-emacs state"))
        (should-not (re-search-forward "#<" nil t))))))

(ert-deftest terra-emacs-capture-generic-leaves ()
  (let ((dir (terra-emacs-test-tmpdir)))
    ;; Dired restores through bookmark.el's default record (its directory).
    (let* ((buf (dired-noselect dir))
           (rec (terra-emacs-leaf-capture buf)))
      (should (equal (terra-emacs-leaf-key rec) (list 'file dir)))
      (kill-buffer buf)
      (should (eq (with-current-buffer (terra-emacs-leaf-restore rec) major-mode) 'dired-mode)))
    ;; A missing file gives a placeholder, never a prompt.
    (let ((rec (list "gone" (cons 'filename (expand-file-name "missing.txt" dir)))))
      (should (string-match-p "terra-emacs" (buffer-name (terra-emacs-leaf-restore rec)))))
    ;; A plain buffer comes back by name.
    (let ((rec (terra-emacs-leaf-capture (get-buffer-create "*plain*"))))
      (kill-buffer "*plain*")
      (should (equal (buffer-name (terra-emacs-leaf-restore rec)) "*plain*")))))

(provide 'test-terra-emacs-capture)
;;; test-terra-emacs-capture.el ends here
