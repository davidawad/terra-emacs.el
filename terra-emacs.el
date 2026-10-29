;;; terra-emacs.el --- Declarative workspaces and layouts: plan and apply -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; Version: 0.2.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: frames, convenience
;; URL: https://github.com/davidawad/terra-emacs.el
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; terra-emacs is declarative configuration for Emacs workspaces, in the
;; manner of terraform: a state file says which workspaces exist (name,
;; level, order) and how each is laid out (a split tree whose leaves are
;; bookmark records: files, dired, eshell, eat and vterm terminals with
;; their cwd and command, Claude Code sessions by id).  terra-emacs reads
;; such a file and converges the live Emacs on it.
;;
;;   `terra-emacs-plan'          what converging on a state would do
;;   `terra-emacs-apply'         do it (DRY-RUN: only plan); idempotent
;;   `terra-emacs-apply-set'     converge on a named set
;;   `terra-emacs-restore-at-start'   apply the autosave set at start
;;
;; Workspaces come from a backend: tab-bar tabs (levels are tab groups)
;; or persp-mode perspectives; see terra-emacs-backend.el to add one.
;; README.md describes the file format.  The companion package
;; terra-emacs-capture writes state files from a live Emacs.

;;; Code:

(require 'terra-emacs-backend)
(require 'terra-emacs-persp)
(require 'terra-emacs-leaf)
(require 'terra-emacs-layout)
(require 'terra-emacs-state)
(require 'terra-emacs-plan)
(require 'terra-emacs-handlers)
(require 'terra-emacs-claude)
(require 'terra-emacs-sets)

(provide 'terra-emacs)
;;; terra-emacs.el ends here
