# uwp-crossbuild — install, uninstall, check.
#
# The scripts find their siblings and include/msvc-compat.h relative to
# themselves, so they are installed as a tree under $(LIBDIR) and exposed
# through symlinks in $(BINDIR). Installing them individually would break
# build.sh, which needs the include directory next to it.
#
#   make install                    # into ~/.local
#   sudo make install PREFIX=/usr   # system-wide
#   make check                      # the same suite CI runs

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib/uwp-crossbuild
DOCDIR ?= $(PREFIX)/share/doc/uwp-crossbuild

SCRIPTS := build.sh build-app.sh build-project.sh check-deps.sh fetch-sdk.sh \
           fix-header-case.sh gen-projection.sh gen-resources.sh \
           restore-nuget.sh wine-tool.sh
# read-vcxproj.py is Python because it is 500 lines of MSBuild evaluator, which
# does not belong in a heredoc. It is installed and exposed like the rest.
SCRIPTS += read-vcxproj.py

# Sourced by those, never run: installed beside them, given no symlink, and not
# executable, so that nothing mistakes it for a command.
LIBS := common.sh

# Exposed on PATH under a uwp- prefix: `build.sh` alone in ~/.local/bin would be
# an unusually good way to collide with something.
LINKS := $(patsubst %.py,uwp-%,$(patsubst %.sh,uwp-%,$(SCRIPTS)))

.PHONY: all install uninstall check lint

all:
	@echo "nothing to build — these are scripts. Try: make install, make check"

install:
	install -d $(DESTDIR)$(LIBDIR)/scripts $(DESTDIR)$(LIBDIR)/include \
	           $(DESTDIR)$(BINDIR) $(DESTDIR)$(DOCDIR)
	install -m 0755 $(addprefix scripts/,$(SCRIPTS)) $(DESTDIR)$(LIBDIR)/scripts/
	install -m 0644 $(addprefix scripts/,$(LIBS)) $(DESTDIR)$(LIBDIR)/scripts/
	install -m 0644 include/msvc-compat.h $(DESTDIR)$(LIBDIR)/include/
	install -m 0644 README.md CHANGELOG.md LICENSE $(DESTDIR)$(DOCDIR)/
	install -m 0644 docs/*.md $(DESTDIR)$(DOCDIR)/
	@set -e; for s in $(SCRIPTS); do \
		n=$${s%.sh}; n=$${n%.py}; \
		ln -sf $(LIBDIR)/scripts/$$s $(DESTDIR)$(BINDIR)/uwp-$$n; \
	done
	@echo "installed to $(PREFIX); $(BINDIR) must be on PATH"
	@echo "try: uwp-check-deps"

uninstall:
	rm -f $(addprefix $(DESTDIR)$(BINDIR)/,$(LINKS))
	rm -rf $(DESTDIR)$(LIBDIR) $(DESTDIR)$(DOCDIR)

check: lint
	tests/run-tests.sh

# Every bash file in the tree, packaging included: publish-aur.sh pushes to the
# AUR, which is no place for the one script nothing checks.
SHELL_FILES := scripts/*.sh tests/*.sh packaging/*.sh

lint:
	shellcheck $(SHELL_FILES)
	python3 -m py_compile scripts/*.py
	@# `cmd -v shfmt && shfmt -d ... || echo` would report a *diff* as "not
	@# installed" and exit 0, so make check passed on unformatted scripts.
	@if command -v shfmt >/dev/null; then \
		shfmt -d $(SHELL_FILES); \
	else \
		echo "shfmt not installed, skipping format check"; \
	fi
