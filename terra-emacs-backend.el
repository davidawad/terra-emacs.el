;;; terra-emacs-backend.el --- workspace backends for terra-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: frames, convenience
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A workspace is whatever an Emacs "workspace" package calls one: a
;; tab-bar tab, a persp-mode perspective, ...  terra-emacs talks to them
;; through the generic functions below, dispatched on a backend symbol,
;; and addresses a workspace by its NAME.  Each workspace also carries:
;;
;;   level  the group it sits in (a tab-bar tab group, a perspective
;;          parameter); any `equal'-comparable value, nil for none.
;;   id     a stable string terra-emacs assigns so a rename is a rename
;;          rather than a kill plus a create.
;;
;; The set of levels a state declares (`(:id ID :name NAME)' plists) is
;; kept in `terra-emacs-levels' and announced on
;; `terra-emacs-levels-functions', unless a backend stores it itself.
;;
;; To add a backend (perspective.el, tabspaces, ...), define methods for
;; every generic below `(eql BACKEND)' and add BACKEND to
;; `terra-emacs-backend-candidates'.  This file holds tab-bar's methods;
;; terra-emacs-persp.el holds persp-mode's.

;;; Code:

(require 'cl-lib)
(require 'tab-bar)

(defgroup terra-emacs nil
  "Declarative workspaces and layouts: capture, plan, apply."
  :group 'convenience
  :prefix "terra-emacs-")

(defcustom terra-emacs-backend nil
  "The workspace backend: a symbol such as `tab-bar' or `persp-mode'.
Nil picks the first available of `terra-emacs-backend-candidates'."
  :type '(choice (const :tag "Automatic" nil) symbol))

(defcustom terra-emacs-backend-candidates '(persp-mode tab-bar)
  "Backends tried, in order, when `terra-emacs-backend' is nil."
  :type '(repeat symbol))

(defcustom terra-emacs-tab-bar-saved-parameters nil
  "Keys of a tab's alist captured and applied as its saved parameters."
  :type '(repeat symbol))

(defvar terra-emacs-levels nil
  "The declared levels, a list of (:id ID :name NAME) plists.")

(defvar terra-emacs-levels-functions nil
  "Functions called with the levels list whenever a state declares it.")

;;;; The protocol

(cl-defgeneric terra-emacs-backend-available-p (backend)
  "Non-nil when BACKEND can be used now.")

(cl-defgeneric terra-emacs-backend-workspaces (backend)
  "The names of BACKEND's workspaces, in display order.")

(cl-defgeneric terra-emacs-backend-current (backend)
  "The name of BACKEND's shown workspace.")

(cl-defgeneric terra-emacs-backend-select (backend name)
  "Show BACKEND's workspace NAME.")

(cl-defgeneric terra-emacs-backend-create (backend name)
  "Create the workspace NAME in BACKEND, last, without showing it.")

(cl-defgeneric terra-emacs-backend-rename (backend old new)
  "Rename BACKEND's workspace OLD to NEW.")

(cl-defgeneric terra-emacs-backend-kill (backend name)
  "Remove BACKEND's workspace NAME (its buffers stay).")

(cl-defgeneric terra-emacs-backend-move (backend name index)
  "Move BACKEND's workspace NAME to position INDEX (0-based).")

(cl-defgeneric terra-emacs-backend-level (backend name)
  "The level of BACKEND's workspace NAME, or nil.")

(cl-defgeneric terra-emacs-backend-set-level (backend name level)
  "Put BACKEND's workspace NAME in LEVEL (nil: no level).")

(cl-defgeneric terra-emacs-backend-id (backend name)
  "The terra-emacs id of BACKEND's workspace NAME, or nil.")

(cl-defgeneric terra-emacs-backend-set-id (backend name id)
  "Record ID as the terra-emacs id of BACKEND's workspace NAME.")

(cl-defgeneric terra-emacs-backend-parameters (_backend _name)
  "The saved parameters of BACKEND's workspace NAME: ((PARAM . VALUE) ...).
Which parameters a backend saves is its own option; nil values are left out."
  nil)

(cl-defgeneric terra-emacs-backend-set-parameter (_backend _name _param _value)
  "Set the saved parameter PARAM of BACKEND's workspace NAME to VALUE."
  nil)

(cl-defgeneric terra-emacs-backend-window-state (_backend _name)
  "The window state BACKEND keeps for its hidden workspace NAME, or nil.
Capturing reads a hidden workspace off it instead of showing it."
  nil)

(cl-defgeneric terra-emacs-backend-add-buffer (_backend _name _buffer)
  "Note that BUFFER belongs to workspace NAME (persp-mode keeps buffer lists)."
  nil)

(cl-defgeneric terra-emacs-backend-levels (_backend)
  "The levels BACKEND declares: (:id ID :name NAME) plists."
  terra-emacs-levels)

(cl-defgeneric terra-emacs-backend-set-levels (_backend levels)
  "Declare LEVELS, a list of (:id ID :name NAME) plists."
  (setq terra-emacs-levels levels)
  (run-hook-with-args 'terra-emacs-levels-functions levels))

(cl-defgeneric terra-emacs-backend-with-workspace (backend name fn)
  "Call FN with BACKEND's workspace NAME shown, then show the one shown before."
  (let ((shown (terra-emacs-backend-current backend)))
    (if (equal shown name)
        (funcall fn)
      (terra-emacs-backend-select backend name)
      (unwind-protect (funcall fn)
        (when (member shown (terra-emacs-backend-workspaces backend))
          (terra-emacs-backend-select backend shown))))))

(defun terra-emacs-current-backend ()
  "The backend in use: `terra-emacs-backend', else the first available."
  (or terra-emacs-backend
      (cl-find-if #'terra-emacs-backend-available-p terra-emacs-backend-candidates)
      (error "terra-emacs: no workspace backend is available")))

(defun terra-emacs-new-id ()
  "A fresh workspace id."
  (format "%08x%04x" (random #xffffffff) (random #xffff)))

;;;; tab-bar: a workspace is a tab of the selected frame, a level its group

(defun terra-emacs-tab-bar--tabs ()
  "The selected frame's tabs."
  (funcall tab-bar-tabs-function))

(defun terra-emacs-tab-bar--index (name)
  "The 0-based index of the tab NAME; an error when there is none."
  (or (cl-position name (terra-emacs-tab-bar--tabs)
                   :key (lambda (tab) (alist-get 'name tab)) :test #'equal)
      (error "terra-emacs: no tab named %S" name)))

(defun terra-emacs-tab-bar--tab (name)
  "The tab NAME (the cell in the frame's tab list)."
  (nth (terra-emacs-tab-bar--index name) (terra-emacs-tab-bar--tabs)))

(cl-defmethod terra-emacs-backend-available-p ((_ (eql 'tab-bar)))
  "Tabs exist in every Emacs this package supports."
  (fboundp 'tab-bar-new-tab))

(cl-defmethod terra-emacs-backend-workspaces ((_ (eql 'tab-bar)))
  (mapcar (lambda (tab) (alist-get 'name tab)) (terra-emacs-tab-bar--tabs)))

(cl-defmethod terra-emacs-backend-current ((_ (eql 'tab-bar)))
  (alist-get 'name (assq 'current-tab (terra-emacs-tab-bar--tabs))))

(cl-defmethod terra-emacs-backend-select ((_ (eql 'tab-bar)) name)
  (tab-bar-select-tab (1+ (terra-emacs-tab-bar--index name))))

(cl-defmethod terra-emacs-backend-create ((_ (eql 'tab-bar)) name)
  (let ((shown (terra-emacs-backend-current 'tab-bar))
        (tab-bar-new-tab-choice "*scratch*")
        (tab-bar-new-tab-to 'rightmost)
        (tab-bar-new-tab-group nil))
    (tab-bar-new-tab)
    (tab-bar-rename-tab name)
    (terra-emacs-backend-select 'tab-bar shown)))

(cl-defmethod terra-emacs-backend-rename ((_ (eql 'tab-bar)) old new)
  (tab-bar-rename-tab new (1+ (terra-emacs-tab-bar--index old))))

(cl-defmethod terra-emacs-backend-kill ((_ (eql 'tab-bar)) name)
  (tab-bar-close-tab (1+ (terra-emacs-tab-bar--index name))))

(cl-defmethod terra-emacs-backend-move ((_ (eql 'tab-bar)) name index)
  (let ((last (1- (length (terra-emacs-tab-bar--tabs)))))
    (tab-bar-move-tab-to (1+ (min index last))
                         (1+ (terra-emacs-tab-bar--index name)))))

(cl-defmethod terra-emacs-backend-level ((_ (eql 'tab-bar)) name)
  (alist-get 'group (terra-emacs-tab-bar--tab name)))

(cl-defmethod terra-emacs-backend-set-level ((_ (eql 'tab-bar)) name level)
  (let ((tab (terra-emacs-tab-bar--tab name)))
    (if level
        (tab-bar-change-tab-group (format "%s" level)
                                  (1+ (terra-emacs-tab-bar--index name)))
      (setcdr tab (assq-delete-all 'group (cdr tab)))
      (force-mode-line-update))))

(cl-defmethod terra-emacs-backend-id ((_ (eql 'tab-bar)) name)
  (alist-get 'terra-emacs-id (terra-emacs-tab-bar--tab name)))

(cl-defmethod terra-emacs-backend-set-id ((_ (eql 'tab-bar)) name id)
  ;; tab-bar copies unknown keys of a tab along when it saves the tab.
  (let ((tab (terra-emacs-tab-bar--tab name)))
    (setcdr tab (cons (cons 'terra-emacs-id id)
                      (assq-delete-all 'terra-emacs-id (cdr tab))))))

(cl-defmethod terra-emacs-backend-window-state ((_ (eql 'tab-bar)) name)
  (let ((tab (terra-emacs-tab-bar--tab name)))
    (unless (eq (car tab) 'current-tab) (alist-get 'ws (cdr tab)))))

(cl-defmethod terra-emacs-backend-parameters ((_ (eql 'tab-bar)) name)
  (let ((tab (terra-emacs-tab-bar--tab name)))
    (cl-loop for p in terra-emacs-tab-bar-saved-parameters
             for v = (alist-get p (cdr tab))
             when v collect (cons p v))))

(cl-defmethod terra-emacs-backend-set-parameter ((_ (eql 'tab-bar)) name param value)
  (let ((tab (terra-emacs-tab-bar--tab name)))
    (setcdr tab (cons (cons param value) (assq-delete-all param (cdr tab))))))

(provide 'terra-emacs-backend)
;;; terra-emacs-backend.el ends here
