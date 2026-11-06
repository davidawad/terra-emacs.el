;;; test-terra-emacs-program.el --- program leaves and the registry -*- lexical-binding: t; -*-

;;; Commentary:
;; The registry and how a leaf overrides it.

;;; Code:

(require 'terra-emacs-test-helper
         (expand-file-name "terra-emacs-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'terra-emacs-program)

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

(provide 'test-terra-emacs-program)
;;; test-terra-emacs-program.el ends here
