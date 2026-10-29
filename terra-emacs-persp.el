;;; terra-emacs-persp.el --- persp-mode backend for terra-emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A workspace is a perspective.  persp-mode's nil perspective (named
;; `persp-nil-name') is not a workspace: it cannot be renamed or killed.
;; Display order is `persp-names-cache' (what Doom's workspace bar
;; shows), or, when `terra-emacs-persp-order-parameter' names one, that
;; numeric perspective parameter.  The level and the id are perspective
;; parameters too, which persp-mode saves with its session.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-backend)

(defvar persp-mode)
(defvar persp-nil-name)
(defvar persp-names-cache)
(defvar *persp-hash*)
(declare-function persp-names "persp-mode" (&optional phash reverse))
(declare-function persp-get-by-name "persp-mode" (name &optional phash default))
(declare-function persp-parameter "persp-mode" (param-name &optional persp))
(declare-function set-persp-parameter "persp-mode" (param-name value &optional persp))
(declare-function persp-name "persp-mode" (persp))
(declare-function persp-add-new "persp-mode" (name &optional phash))
(declare-function persp-switch "persp-mode" (name &optional frame window called-interactively-p))
(declare-function persp-rename "persp-mode" (newname &optional persp phash))
(declare-function persp-kill "persp-mode" (name &optional dont-kill-buffers called-interactively-p))
(declare-function persp-add-buffer "persp-mode"
                  (&optional buffs-or-names persp switchorno called-interactively-p))
(declare-function get-current-persp "persp-mode" (&optional frame window))

(defcustom terra-emacs-persp-level-parameter 'terra-emacs-level
  "Perspective parameter holding a workspace's level."
  :type 'symbol :group 'terra-emacs)

(defcustom terra-emacs-persp-id-parameter 'terra-emacs-id
  "Perspective parameter holding a workspace's terra-emacs id."
  :type 'symbol :group 'terra-emacs)

(defcustom terra-emacs-persp-order-parameter nil
  "Perspective parameter holding a workspace's position, or nil.
Nil orders workspaces as `persp-names-cache' does."
  :type '(choice (const nil) symbol) :group 'terra-emacs)

(defun terra-emacs-persp--get (name)
  "The perspective NAME; an error when there is none."
  (let ((p (persp-get-by-name name *persp-hash* :none)))
    (when (eq p :none) (error "terra-emacs: no perspective named %S" name))
    p))

(defun terra-emacs-persp--names ()
  "Perspective names but the nil one, in `persp-names-cache' order."
  (let ((all (persp-names)))
    (cl-remove-if (lambda (n) (or (equal n persp-nil-name) (not (member n all))))
                  (cl-remove-duplicates
                   (append (and (boundp 'persp-names-cache) persp-names-cache) all)
                   :test #'equal :from-end t))))

(defun terra-emacs-persp--set-order (names)
  "Make NAMES the display order."
  (setq persp-names-cache
        (append (cl-remove-if-not (lambda (n) (equal n persp-nil-name)) persp-names-cache)
                names))
  (when terra-emacs-persp-order-parameter
    (cl-loop for n in names for i from 0
             do (set-persp-parameter terra-emacs-persp-order-parameter i
                                     (terra-emacs-persp--get n)))))

(cl-defmethod terra-emacs-backend-available-p ((_ (eql 'persp-mode)))
  (and (bound-and-true-p persp-mode) (fboundp 'persp-names)))

(cl-defmethod terra-emacs-backend-workspaces ((_ (eql 'persp-mode)))
  (let ((names (terra-emacs-persp--names)))
    (if (not terra-emacs-persp-order-parameter)
        names
      (cl-stable-sort names #'<
                      :key (lambda (n)
                             (let ((o (persp-parameter terra-emacs-persp-order-parameter
                                                       (terra-emacs-persp--get n))))
                               (if (numberp o) o most-positive-fixnum)))))))

(cl-defmethod terra-emacs-backend-current ((_ (eql 'persp-mode)))
  (let ((p (get-current-persp)))
    (if p (persp-name p) persp-nil-name)))

(cl-defmethod terra-emacs-backend-select ((_ (eql 'persp-mode)) name)
  (persp-switch name))

(cl-defmethod terra-emacs-backend-create ((_ (eql 'persp-mode)) name)
  (let ((order (terra-emacs-backend-workspaces 'persp-mode)))
    (persp-add-new name)
    (terra-emacs-persp--set-order (append (remove name order) (list name)))))

(cl-defmethod terra-emacs-backend-rename ((_ (eql 'persp-mode)) old new)
  (let ((order (terra-emacs-backend-workspaces 'persp-mode)))
    (persp-rename new (terra-emacs-persp--get old))
    (terra-emacs-persp--set-order (cl-substitute new old order :test #'equal))))

(cl-defmethod terra-emacs-backend-kill ((_ (eql 'persp-mode)) name)
  (let ((order (terra-emacs-backend-workspaces 'persp-mode)))
    (persp-kill name t)
    (terra-emacs-persp--set-order (remove name order))))

(cl-defmethod terra-emacs-backend-move ((_ (eql 'persp-mode)) name index)
  (let* ((order (remove name (terra-emacs-backend-workspaces 'persp-mode)))
         (index (min index (length order))))
    (terra-emacs-persp--set-order
     (append (cl-subseq order 0 index) (list name) (nthcdr index order)))))

(cl-defmethod terra-emacs-backend-level ((_ (eql 'persp-mode)) name)
  (persp-parameter terra-emacs-persp-level-parameter (terra-emacs-persp--get name)))

(cl-defmethod terra-emacs-backend-set-level ((_ (eql 'persp-mode)) name level)
  (set-persp-parameter terra-emacs-persp-level-parameter level (terra-emacs-persp--get name)))

(cl-defmethod terra-emacs-backend-id ((_ (eql 'persp-mode)) name)
  (persp-parameter terra-emacs-persp-id-parameter (terra-emacs-persp--get name)))

(cl-defmethod terra-emacs-backend-set-id ((_ (eql 'persp-mode)) name id)
  (set-persp-parameter terra-emacs-persp-id-parameter id (terra-emacs-persp--get name)))

(cl-defmethod terra-emacs-backend-add-buffer ((_ (eql 'persp-mode)) name buffer)
  (persp-add-buffer buffer (terra-emacs-persp--get name) nil nil))

(provide 'terra-emacs-persp)
;;; terra-emacs-persp.el ends here
