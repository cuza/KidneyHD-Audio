# make                  build the audio plug-in and the control daemon (signed with your Developer ID if found)
# make test             USB engine check against a plugged-in pedal; the pedal must be free
#                       (no audio playing through it, control daemon stopped)
# make check            Core Audio check through the installed plug-in
# make latency          round-trip latency to report (output cabled to input, empty preset)
# sudo make install     install both;  sudo make uninstall  removes both
# sudo make install-daemon / uninstall-daemon   only the control daemon (editors, keeps the pedal unmuted)
# make pkg              build/KidneyHD-Audio.pkg installer (signed if a Developer ID Installer cert exists)
# make notarize         notarize and staple the pkg (needs: xcrun notarytool store-credentials kidneyhd-audio,
#                       or pass NOTARY_PROFILE=<name>)
#
# Override the signing identities with IDENTITY=... and INSTALLER_IDENTITY=..., for example
# make IDENTITY="Developer ID Application: Your Name (TEAMID)".

BUNDLE := build/KidneyHDAudio.driver
HAL := /Library/Audio/Plug-Ins/HAL
CFLAGS := -O2 -Wall -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=14.0
FRAMEWORKS := -framework CoreAudio -framework CoreFoundation -framework Foundation -framework IOKit -framework IOUSBHost
IDENTITY ?= $(shell security find-identity -v -p codesigning | grep -m1 'Developer ID Application' | awk '{print $$2}')
INSTALLER_IDENTITY ?= $(shell security find-identity -v | grep -m1 'Developer ID Installer' | awk '{print $$2}')
SIGN = codesign --force --options runtime $(if $(IDENTITY),--timestamp,--timestamp=none) --sign "$(or $(IDENTITY),-)"
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' src/Info.plist)
# One file name for every version, so releases/latest/download/KidneyHD-Audio.pkg is the newest.
PKG := build/KidneyHD-Audio.pkg
NOTARY_PROFILE ?= kidneyhd-audio
# Optional: an editor app to bundle into the pkg, e.g. make pkg EDITOR_APP="path/to/Editor.app".
# Public releases ship the driver only.
EDITOR_APP ?=

DAEMON_DIR := /Library/Application Support/KidneyHD Audio
PLIST := /Library/LaunchDaemons/dev.cuza.kidneyhd-audiod.plist

all: $(BUNDLE) build/kidneyhd-audiod

build/kidneyhd-audiod: daemon/kidneyhd-audiod.m
	mkdir -p build
	clang $(CFLAGS) -framework Foundation -framework IOKit -framework IOUSBHost $< -o $@
	$(SIGN) $@

$(BUNDLE): src/driver.c src/usb.m src/pod.h src/Info.plist res/KidneyHDAudio.icns
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp src/Info.plist $(BUNDLE)/Contents/
	# res/KidneyHDAudio.icns is built from res/icon.svg with rsvg-convert and iconutil.
	mkdir -p $(BUNDLE)/Contents/Resources
	cp res/KidneyHDAudio.icns $(BUNDLE)/Contents/Resources/
	clang $(CFLAGS) -bundle $(FRAMEWORKS) src/driver.c src/usb.m -o $(BUNDLE)/Contents/MacOS/KidneyHDAudio
	$(SIGN) $(BUNDLE)

build/podtest: tools/podtest.m src/usb.m src/pod.h
	mkdir -p build
	clang $(CFLAGS) -framework Foundation -framework IOKit -framework IOUSBHost src/usb.m tools/podtest.m -o $@

test: build/podtest
	build/podtest 5

build/halcheck: tools/halcheck.c
	mkdir -p build
	clang -O2 -Wall -framework CoreAudio -framework CoreFoundation $< -o $@

check: build/halcheck
	build/halcheck 5

build/latency: tools/latency.c
	mkdir -p build
	clang -O2 -Wall -framework CoreAudio -framework CoreFoundation $< -o $@

# Round-trip latency beyond the buffer and safety offsets, which the driver reports split evenly
# between input and output. Needs an output cabled back into the input and a preset with no amp and
# no effects.
latency: build/latency
	build/latency 6

# Installs copy only; run `make` as yourself first so the build isn't owned by root.
install: install-daemon install-plugin

install-plugin:
	test -d $(BUNDLE) || { echo "run make first"; exit 1; }
	rm -rf $(HAL)/KidneyHDAudio.driver
	cp -R $(BUNDLE) $(HAL)/
	killall -9 coreaudiod

install-daemon:
	test -f build/kidneyhd-audiod || { echo "run make first"; exit 1; }
	-launchctl bootout system $(PLIST) 2>/dev/null
	mkdir -p "$(DAEMON_DIR)"
	cp build/kidneyhd-audiod "$(DAEMON_DIR)/"
	cp daemon/dev.cuza.kidneyhd-audiod.plist $(PLIST)
	launchctl bootstrap system $(PLIST)

uninstall: uninstall-daemon
	rm -rf $(HAL)/KidneyHDAudio.driver
	killall -9 coreaudiod

uninstall-daemon:
	-launchctl bootout system $(PLIST)
	rm -rf $(PLIST) "$(DAEMON_DIR)" /var/run/kidneyhd-audiod.sock

# Installs the same files as `make install`, plus uninstall.sh.
pkg: $(BUNDLE) build/kidneyhd-audiod
	rm -rf build/pkgroot build/component.pkg
	mkdir -p build/pkgroot/Library/Audio/Plug-Ins/HAL "build/pkgroot/Library/Application Support/KidneyHD Audio" build/pkgroot/Library/LaunchDaemons
	cp -R $(BUNDLE) build/pkgroot/Library/Audio/Plug-Ins/HAL/
	cp build/kidneyhd-audiod pkg/uninstall.sh "build/pkgroot/Library/Application Support/KidneyHD Audio/"
	cp daemon/dev.cuza.kidneyhd-audiod.plist build/pkgroot/Library/LaunchDaemons/
	@if [ -n "$(EDITOR_APP)" ]; then test -d "$(EDITOR_APP)" || { echo "EDITOR_APP not found: $(EDITOR_APP)"; exit 1; }; \
	  mkdir -p build/pkgroot/Applications && ditto "$(EDITOR_APP)" "build/pkgroot/Applications/$$(basename "$(EDITOR_APP)")"; fi
	pkgbuild --analyze --root build/pkgroot build/components.plist
	# Without this, Installer may "relocate" a bundle to any other copy it finds, such as build/KidneyHDAudio.driver.
	sed -i '' '/BundleIsRelocatable/{n;s/<true\/>/<false\/>/;}' build/components.plist
	pkgbuild --root build/pkgroot --component-plist build/components.plist --scripts pkg/scripts \
	  --identifier dev.cuza.kidneyhd-audio --version $(VERSION) --install-location / build/component.pkg
	productbuild --package build/component.pkg $(if $(INSTALLER_IDENTITY),--sign "$(INSTALLER_IDENTITY)") $(PKG)
	@echo "built $(PKG)$(if $(INSTALLER_IDENTITY),, (unsigned: no Developer ID Installer certificate))"

notarize: pkg
	@test -n "$(IDENTITY)" -a -n "$(INSTALLER_IDENTITY)" || \
	  { echo "notarize needs a Developer ID Application and a Developer ID Installer identity"; exit 1; }
	xcrun notarytool submit $(PKG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(PKG)

clean:
	rm -rf build

.PHONY: all test check latency install install-plugin install-daemon uninstall uninstall-daemon pkg notarize clean
