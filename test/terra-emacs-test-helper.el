;;; terra-emacs-test-helper.el --- shared setup for terra-emacs ERT -*- lexical-binding: t; -*-

;;; Commentary:
;; Load paths (the package, and the pinned test packages for eat and
;; persp-mode when present) and resets every suite uses.  Batch Emacs
;; has one 80x25 frame; tab-bar works there, and so does persp-mode.

;;; Code:

(require 'ert)
(require 'cl-lib)

(defconst terra-emacs-test-dir
  (file-name-directory (or load-file-name buffer-file-name))
  "This directory.")

(add-to-list 'load-path (expand-file-name ".." terra-emacs-test-dir))

(defconst terra-emacs-test-packages
  (or (getenv "TERRA_EMACS_TEST_PACKAGES") "/opt/emacs-test-packages")
  "Where the pinned third-party test packages live.")

(dolist (dir (append (list (expand-file-name "eat-0.9.4" terra-emacs-test-packages)
                           (expand-file-name "external/pkg-persp-mode" terra-emacs-test-packages))
                     ;; Or name the package directories, colon-separated.
                     (split-string (or (getenv "TERRA_EMACS_TEST_LOAD_PATH") "") ":" t)))
  (when (file-directory-p dir) (add-to-list 'load-path (expand-file-name dir) t)))

(defun terra-emacs-test-have (feature)
  "Non-nil when FEATURE loads."
  (ignore-errors (require feature) t))

(defun terra-emacs-test-reset-tabs ()
  "Leave one tab, named \"*reset*\", showing *scratch* in one window."
  (require 'tab-bar)
  (while (> (length (funcall tab-bar-tabs-function)) 1)
    (tab-bar-close-tab 2))
  (let ((tab (assq 'current-tab (funcall tab-bar-tabs-function))))
    (setcdr tab (cl-remove-if (lambda (c) (memq (car-safe c) '(terra-emacs-id group)))
                              (cdr tab))))
  (tab-bar-rename-tab "*reset*")
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun terra-emacs-test-persp-on ()
  "Turn persp-mode on with no autosave/resume; kill every perspective."
  (require 'persp-mode)
  (setq persp-auto-resume-time -1 persp-auto-save-opt 0)
  (unless (bound-and-true-p persp-mode) (persp-mode 1))
  (dolist (name (persp-names))
    (unless (equal name persp-nil-name) (persp-kill name t)))
  (delete-other-windows)
  (switch-to-buffer "*scratch*"))

(defun terra-emacs-test-persp-off ()
  "Turn persp-mode off."
  (when (bound-and-true-p persp-mode) (persp-mode -1)))

(defun terra-emacs-test-tmpdir ()
  "A fresh temporary directory (with a trailing slash)."
  (file-name-as-directory (make-temp-file "terra-emacs-test" t)))

(provide 'terra-emacs-test-helper)
;;; terra-emacs-test-helper.el ends here
