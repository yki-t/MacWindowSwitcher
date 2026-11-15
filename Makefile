APP := build/WindowSwitcher.app
# The login item records the app path. `make app` and `make clean` delete
# build/WindowSwitcher.app, so the login item must point to a copy outside
# of build/.
INSTALL_APP := $(HOME)/Applications/WindowSwitcher.app
# An ad hoc signature changes with each build, and macOS then asks for the
# permissions again. A fixed certificate keeps the permissions.
SIGN_IDENTITY ?= window-switcher

.PHONY: app install clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/WindowSwitcher $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

# The old process enables the native Cmd+Tab when it stops. If it stops after
# the new process starts, the native Cmd+Tab stays enabled.
# rsync updates the installed bundle in place. The login item refers to that
# bundle, so do not delete the bundle directory and create it again.
install: app
	-pkill -x WindowSwitcher
	while pgrep -x WindowSwitcher >/dev/null; do sleep 0.1; done
	mkdir -p $(dir $(INSTALL_APP))
	rsync -a --delete $(APP)/ $(INSTALL_APP)/
	open $(INSTALL_APP)

clean:
	rm -rf .build build
