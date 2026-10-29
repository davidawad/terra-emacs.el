# terra-emacs: declarative Emacs workspaces and layouts.
#
#   make test      byte-compile (warnings as errors), then every ERT suite
#   make compile   byte-compile only
#   make clean     remove byte-compiled files

EMACS ?= emacs
export EMACS

.PHONY: all test compile clean

all: test

test:
	bash test/test_terra_emacs.sh

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile terra-emacs*.el

clean:
	rm -f *.elc
