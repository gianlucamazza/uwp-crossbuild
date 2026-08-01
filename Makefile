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

SCRIPTS := build.sh build-app.sh check-deps.sh fetch-sdk.sh \
           fix-header-case.sh gen-projection.sh gen-resources.sh wine-tool.sh

# Exposed on PATH under a uwp- prefix: `build.sh` alone in ~/.local/bin would be
# an unusually good way to collide with something.
LINKS := $(patsubst %.sh,uwp-%,$(SCRIPTS))

.PHONY: all install uninstall check lint

all:
	@echo "nothing to build — these are scripts. Try: make install, make check"

install:
	install -d $(DESTDIR)$(LIBDIR)/scripts $(DESTDIR)$(LIBDIR)/include \
	           $(DESTDIR)$(BINDIR) $(DESTDIR)$(DOCDIR)
	install -m 0755 $(addprefix scripts/,$(SCRIPTS)) $(DESTDIR)$(LIBDIR)/scripts/
	install -m 0644 include/msvc-compat.h $(DESTDIR)$(LIBDIR)/include/
	install -m 0644 README.md CHANGELOG.md LICENSE $(DESTDIR)$(DOCDIR)/
	@set -e; for s in $(SCRIPTS); do \
		ln -sf $(LIBDIR)/scripts/$$s $(DESTDIR)$(BINDIR)/uwp-$${s%.sh}; \
	done
	@echo "installed to $(PREFIX); $(BINDIR) must be on PATH"
	@echo "try: uwp-check-deps"

uninstall:
	rm -f $(addprefix $(DESTDIR)$(BINDIR)/,$(LINKS))
	rm -rf $(DESTDIR)$(LIBDIR) $(DESTDIR)$(DOCDIR)

check: lint
	tests/run-tests.sh

lint:
	shellcheck scripts/*.sh tests/*.sh
	@command -v shfmt >/dev/null && shfmt -d scripts/*.sh tests/*.sh || \
		echo "shfmt not installed, skipping format check"
