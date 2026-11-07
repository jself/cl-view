# Wraps `zig build`. `make` builds cl, plus cl-window when it can; `make
# install` puts them in $(PREFIX)/bin. See README, "Build".

# Zig 0.16.0 exactly: zvm's copy when it's there, else the zig on PATH.
ZIG ?= $(firstword $(wildcard $(HOME)/.local/share/zvm/0.16.0/zig) zig)
OPTIMIZE ?= ReleaseSafe
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

BUILD = $(ZIG) build -Doptimize=$(OPTIMIZE)

.PHONY: all cl window test install clean

# cl first, on its own, so it's built even when cl-window can't be: then
# cl-window is skipped (no webkitgtk-6.0) or fails to build, and that only
# warns. An old cl-window is removed so `make install` doesn't copy it.
all: cl
	@if pkg-config --exists webkitgtk-6.0 2>/dev/null; then \
	  echo "$(BUILD) -Dwindow=true"; \
	  $(BUILD) -Dwindow=true || { \
	    rm -f zig-out/bin/cl-window; \
	    echo "make: cl-window failed to build; cl is built, and \`cl window\` will use a browser instead" >&2; \
	  }; \
	else \
	  rm -f zig-out/bin/cl-window; \
	  echo "make: webkitgtk-6.0 not found, so no cl-window; cl is built, and \`cl window\` will use a browser instead" >&2; \
	fi

# The terminal program only.
cl:
	$(BUILD) -Dwindow=false

# cl and cl-window, failing if cl-window can't be built.
window:
	$(BUILD) -Dwindow=true

test:
	$(ZIG) build test --summary all

# Installs what `make` built: cl, and cl-window when it was.
install: all
	install -d $(DESTDIR)$(BINDIR)
	install -m755 zig-out/bin/cl $(DESTDIR)$(BINDIR)/
	@if [ -f zig-out/bin/cl-window ]; then \
	  echo install -m755 zig-out/bin/cl-window $(DESTDIR)$(BINDIR)/; \
	  install -m755 zig-out/bin/cl-window $(DESTDIR)$(BINDIR)/; \
	fi

clean:
	rm -rf zig-out .zig-cache
