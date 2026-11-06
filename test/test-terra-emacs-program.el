;;; test-terra-emacs-program.el --- program leaves and the registry -*- lexical-binding: t; -*-

;;; Commentary:
;; The registry and how a leaf overrides it; the handler starting a
;; program in eat with its args, env and cwd and reusing it live, or
;; calling a registered Lisp launcher; capture giving back the leaf
;; exactly, through a state file.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-program)
(require 'terra-emacs-plan)

(defun terra-emacs-test--wait-file (file)
  "Wait up to 5s for FILE to hold a full line; its contents."
  (cl-loop repeat 100
           until (and (file-exists-p file)
                      (with-temp-buffer (insert-file-contents file)
                                        (string-suffix-p "\n" (buffer-string))))
           do (accept-process-output nil 0.05))
  (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string))))

(defun terra-emacs-test--kill (buffer)
  "Kill BUFFER and its process quietly."
  (when (buffer-live-p buffer)
    (let ((p (get-buffer-process buffer)))
      (when p (set-process-query-on-exit-flag p nil) (delete-process p)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))

(defun terra-emacs-test--define-sh (dir)
  "Register \"sh\": a shell writing its args, $FOO and cwd to DIR/out."
  (terra-emacs-define-program
   "sh" :command "/bin/sh"
   :args (list "-c" "echo \"$0 $FOO $(pwd)\" > out; sleep 30" "one")
   :env '(("FOO" . "registry")) :cwd dir))

(defmacro terra-emacs-test--with-programs (&rest body)
  "Run BODY with an empty program registry."
  (declare (indent 0))
  `(let ((terra-emacs-programs nil)) ,@body))

(defun terra-emacs-test--program-leaf (program &rest props)
  "A program leaf for PROGRAM with PROPS."
  (apply #'terra-emacs-leaf-make (format "*%s*" program)
         'handler 'terra-emacs-program-handler 'program program props))

(ert-deftest terra-emacs-program-registry-merge ()
  (terra-emacs-test--with-programs
    (terra-emacs-define-program "py" :command "python3" :args '("-q")
                                :env '(("PYTHONUNBUFFERED" . "1") ("LANG" . "C"))
                                :cwd "/tmp/" :config '(:theme dark :width 80))
    ;; Redefining replaces the entry.
    (terra-emacs-define-program "py" :command "python3" :args '("-q" "-i")
                                :env '(("PYTHONUNBUFFERED" . "1") ("LANG" . "C"))
                                :cwd "/tmp/" :config '(:theme dark :width 80))
    (should (= 1 (length terra-emacs-programs)))
    (let ((spec (terra-emacs-program-spec (terra-emacs-test--program-leaf "py"))))
      (should (equal (plist-get spec :argv) '("python3" "-q" "-i")))
      (should (equal (plist-get spec :env) '(("PYTHONUNBUFFERED" . "1") ("LANG" . "C"))))
      (should (equal (plist-get spec :cwd) "/tmp/"))
      (should (equal (plist-get spec :config) '(:theme dark :width 80)))
      (should (equal (plist-get spec :buffer-name) "*py*")))))

(ert-deftest terra-emacs-program-leaf-override ()
  (terra-emacs-test--with-programs
    (terra-emacs-define-program "py" :command "python3" :args '("-q")
                                :env '(("PYTHONUNBUFFERED" . "1") ("LANG" . "C"))
                                :cwd "/tmp/" :config '(:theme dark :width 80))
    (let ((spec (terra-emacs-program-spec
                 (terra-emacs-test--program-leaf
                  "py" 'args '("-X" "dev") 'env '(("LANG" . "en_US.UTF-8") ("DEBUG" . "1"))
                  'cwd "/srv/" 'config '(:width 120) 'buffer-name "*py work*"))))
      (should (equal (plist-get spec :argv) '("python3" "-X" "dev")))
      (should (equal (plist-get spec :env)
                     '(("PYTHONUNBUFFERED" . "1") ("LANG" . "en_US.UTF-8") ("DEBUG" . "1"))))
      (should (equal (plist-get spec :cwd) "/srv/"))
      (should (equal (plist-get spec :config) '(:theme dark :width 120)))
      (should (equal (plist-get spec :buffer-name) "*py work*")))
    ;; args-append adds to the registry's args.
    (should (equal (plist-get (terra-emacs-program-spec
                               (terra-emacs-test--program-leaf "py" 'args '("-i") 'args-append t))
                              :argv)
                   '("python3" "-q" "-i")))
    ;; An explicit empty args list replaces the registry's.
    (should (equal (plist-get (terra-emacs-program-spec
                               (terra-emacs-test--program-leaf "py" 'args nil))
                              :argv)
                   '("python3")))
    ;; A :command function builds the argv from the merged config.
    (terra-emacs-define-program "w" :command (lambda (spec)
                                               (list "w" (format "--width=%d"
                                                                 (plist-get (plist-get spec :config) :width))))
                                :config '(:width 80))
    (should (equal (plist-get (terra-emacs-program-spec
                               (terra-emacs-test--program-leaf "w" 'config '(:width 99)))
                              :argv)
                   '("w" "--width=99")))
    ;; A program the registry does not name runs as that command.
    (should (equal (plist-get (terra-emacs-program-spec
                               (terra-emacs-test--program-leaf "htop" 'args '("-d" "10")))
                              :argv)
                   '("htop" "-d" "10")))))

(ert-deftest terra-emacs-program-handler-eat ()
  (skip-unless (terra-emacs-test-have 'eat))
  (terra-emacs-test--with-programs
    (let* ((dir (terra-emacs-test-tmpdir))
           (out (expand-file-name "out" dir))
           (rec (progn (terra-emacs-test--define-sh dir)
                       (terra-emacs-test--program-leaf
                        "sh" 'env '(("FOO" . "leaf")) 'buffer-name "*sh work*")))
           (buf (terra-emacs-leaf-restore rec)))
      (unwind-protect
          (let ((pid (process-id (get-buffer-process buf))))
            (should (equal (buffer-name buf) "*sh work*"))
            (should (eq (buffer-local-value 'major-mode buf) 'eat-mode))
            (let ((words (split-string (terra-emacs-test--wait-file out))))
              (should (equal (nth 0 words) "one"))
              (should (equal (nth 1 words) "leaf"))
              (should (equal (file-truename (nth 2 words)) (directory-file-name (file-truename dir)))))
            ;; Restoring again reuses the live process.
            (should (eq (terra-emacs-leaf-restore rec) buf))
            (should (= pid (process-id (get-buffer-process buf))))
            ;; Changed env: the program restarts in the same buffer.
            (rename-file out (concat out ".1"))
            (let ((rec2 (terra-emacs-test--program-leaf
                         "sh" 'env '(("FOO" . "changed")) 'buffer-name "*sh work*")))
              (should (eq (terra-emacs-leaf-restore rec2) buf))
              (should-not (= pid (process-id (get-buffer-process buf))))
              (should (equal (nth 1 (split-string (terra-emacs-test--wait-file out))) "changed"))))
        (terra-emacs-test--kill buf)))))

(ert-deftest terra-emacs-program-handler-launch ()
  (terra-emacs-test--with-programs
    (let ((calls 0))
      (terra-emacs-define-program
       "notes" :process nil :config '(:mode text)
       :launch (lambda (spec)
                 (cl-incf calls)
                 (with-current-buffer (get-buffer-create (plist-get spec :buffer-name))
                   (erase-buffer)
                   (insert (format "%S %s" (plist-get spec :config) default-directory))
                   (current-buffer))))
      (let* ((rec (terra-emacs-test--program-leaf "notes" 'cwd "/" 'config '(:width 7)))
             (buf (terra-emacs-leaf-restore rec)))
        (unwind-protect
            (progn
              (should (equal (buffer-name buf) "*notes*"))
              (should (equal (with-current-buffer buf (buffer-string)) "(:mode text :width 7) /"))
              ;; No process to lose: not stale, and reused.
              (should-not (terra-emacs-leaf-stale-p (terra-emacs-leaf-observe buf)))
              (should (eq (terra-emacs-leaf-restore rec) buf))
              (should (= calls 1))
              ;; Changed config: launched again.
              (terra-emacs-leaf-restore (terra-emacs-test--program-leaf "notes" 'config '(:width 8)))
              (should (= calls 2)))
          (terra-emacs-test--kill buf))))))

(ert-deftest terra-emacs-program-capture-round-trip ()
  (skip-unless (terra-emacs-test-have 'eat))
  (terra-emacs-test--with-programs
    (let* ((dir (terra-emacs-test-tmpdir))
           (rec (progn (terra-emacs-test--define-sh dir)
                       (terra-emacs-test--program-leaf
                        "sh" 'args (list "-c" "sleep 30") 'args-append nil
                        'env '(("FOO" . "leaf")) 'cwd dir 'config '(:k 1)
                        'buffer-name "*sh round*")))
           (state (list :terra-emacs 1
                        :workspaces (list (list :name "*reset*" :layout (list :leaf rec)))))
           (file (expand-file-name "state.eld" dir))
           ;; A generic terminal capture, as terra-emacs-capture installs:
           ;; the program capture runs ahead of it.
           (terra-emacs-leaf-capture-functions terra-emacs-leaf-capture-functions)
           buf)
      (add-hook 'terra-emacs-leaf-capture-functions
                (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'eat-mode)
                                 (terra-emacs-leaf-make (buffer-name b) 'handler
                                                        'terra-emacs-eat-bookmark-handler))))
      (terra-emacs-test-reset-tabs)
      (unwind-protect
          (progn
            (terra-emacs-apply state nil 'tab-bar)
            (setq buf (get-buffer "*sh round*"))
            (should (terra-emacs-handlers--live-p buf))
            (let ((seen (terra-emacs-leaf-observe buf)))
              (should (terra-emacs-leaf-prop seen 'terra-live))
              (should (equal (terra-emacs-leaf-clean seen) rec)))
            ;; Save the live layout to a file and read it back: the same leaf.
            (terra-emacs-write-state
             (list :terra-emacs 1
                   :workspaces (list (list :name "*reset*"
                                           :layout (terra-emacs-layout-clean
                                                    (terra-emacs-layout-current)))))
             file)
            (let ((back (terra-emacs-read-state file)))
              (should (equal (plist-get (plist-get (car (plist-get back :workspaces)) :layout)
                                        :leaf)
                             rec))
              ;; Restoring the saved state changes nothing.
              (should-not (terra-emacs-plan back 'tab-bar))))
        (terra-emacs-test--kill buf)
        (terra-emacs-test-reset-tabs)))))

(provide 'test-terra-emacs-program)
;;; test-terra-emacs-program.el ends here
