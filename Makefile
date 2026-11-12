UUID    := hot-reload@thesalaty.github.io
BUILD   := build
TARGET  := $(HOME)/.local/share/gnome-shell/extensions/$(UUID)

.PHONY: all build install uninstall pack test clean

all: build

build:
	npx tsc -p tsconfig.json
	cp src/metadata.json $(BUILD)/

install: build
	rm -rf $(TARGET)
	mkdir -p $(TARGET)
	cp -r $(BUILD)/. $(TARGET)/
	@echo "Installed to $(TARGET)"
	@gnome-extensions info $(UUID) 2>/dev/null | grep -q ACTIVE \
		|| echo "Log out and back in once, then: gnome-extensions enable $(UUID)"

uninstall:
	rm -rf $(TARGET)

pack: build
	cd $(BUILD) && zip -qr ../$(UUID).shell-extension.zip .
	@echo "Wrote $(UUID).shell-extension.zip"

# Headless shell on a private bus with throwaway XDG dirs; never touches the real session.
test: build
	tools/test.sh

clean:
	rm -rf build $(UUID).shell-extension.zip
