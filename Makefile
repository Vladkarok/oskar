# Packaging seams for omarchy-osk (release plan §7/D2).
#
#   make build   — release helper binary (cargo, locked)
#   make check   — the host-runnable suites (offscreen JS + helper unit)
#   make stage DESTDIR=/staging/root
#                — lay the package's file set out under DESTDIR:
#                  /usr/bin/omarchy-osk            (lifecycle command)
#                  /usr/lib/omarchy-osk/omarchy-osk-daemon
#                  /usr/lib/systemd/user/omarchy-osk.service
#                  /usr/share/omarchy-osk/plugin/  (runtime QML/JS/assets)
#   make install DESTDIR=  — stage into / (for Make-driven installs)
#
# User activation (plugin registration, unit enable) is deliberately NOT
# here: package() writes only files; activation is the explicit, idempotent
# user action `omarchy-osk setup` (audit 2026-09-13, ticket 32).

HELPER := daemon/target/release/omarchy-osk-daemon
DESTDIR ?=

PLUGIN_RUNTIME := Panel.qml BarWidget.qml Keyboard.qml KeyboardLayout.js \
	KeyboardSession.js ModifierReducer.js Config.js Theme.qml \
	CursorPolicy.js CursorPolicy.qml LayoutDevices.js SettleGuard.js \
	EmojiPage.qml EmojiPage.js EmojiCatalog.js \
	LanguageControl.js HoldColumn.js SocketWatch.js Dwell.js \
	ClipboardPaste.js HoverTooltip.qml KeyClickSound.qml \
	SettingsPopover.qml SettingsColorRow.qml SettingsColorEditor.qml \
	SettingsConfirmChip.qml SettingsResetChip.qml \
	SettingsPlacement.js manifest.json

.PHONY: build check stage install

build:
	cargo build --release --locked --manifest-path daemon/Cargo.toml

check: build
	./tools/run-tests.sh

# The packaged unit differs from the source-install unit in exactly one
# line: ExecStart points at the packaged helper instead of %h/.local.
# The transform lives here so systemd/omarchy-osk.service stays the one
# reviewed source.
stage: build
	install -Dm755 bin/omarchy-osk "$(DESTDIR)/usr/bin/omarchy-osk"
	install -Dm755 "$(HELPER)" \
		"$(DESTDIR)/usr/lib/omarchy-osk/omarchy-osk-daemon"
	install -Dm644 systemd/omarchy-osk.service \
		"$(DESTDIR)/usr/lib/systemd/user/omarchy-osk.service.tmp"
	sed 's|^ExecStart=.*|ExecStart=/usr/lib/omarchy-osk/omarchy-osk-daemon|' \
		"$(DESTDIR)/usr/lib/systemd/user/omarchy-osk.service.tmp" \
		> "$(DESTDIR)/usr/lib/systemd/user/omarchy-osk.service"
	rm "$(DESTDIR)/usr/lib/systemd/user/omarchy-osk.service.tmp"
	@# Runtime plugin payload: symlink-free, dev files excluded — the same
	@# set a published checkout validates against.
	set -e; for f in $(PLUGIN_RUNTIME); do \
		install -Dm644 "$$f" "$(DESTDIR)/usr/share/omarchy-osk/plugin/$$f"; done
	install -Dm644 LICENSE "$(DESTDIR)/usr/share/licenses/omarchy-osk/LICENSE"
	install -Dm644 third_party/emoji/LICENSE \
		"$(DESTDIR)/usr/share/licenses/omarchy-osk/emoji-data-LICENSE"
	install -Dm644 -t "$(DESTDIR)/usr/share/omarchy-osk/plugin/assets" assets/*.svg

install: stage
	@echo "staged into DESTDIR='$(DESTDIR)' (no system paths touched)"
