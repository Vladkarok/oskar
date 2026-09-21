# Packaging seams for oskar (release plan §7/D2).
#
#   make build   — release helper binary (cargo, locked)
#   make check   — the host-runnable suites (offscreen JS + helper unit)
#   make stage DESTDIR=/staging/root
#                — lay the package's file set out under DESTDIR:
#                  /usr/bin/oskar            (lifecycle command)
#                  /usr/lib/oskar/oskar-daemon
#                  /usr/lib/systemd/user/oskar.service
#                  /usr/share/oskar/plugin/  (runtime QML/JS/assets)
#   make install DESTDIR=  — stage into / (for Make-driven installs)
#
# User activation (plugin registration, unit enable) is deliberately NOT
# here: package() writes only files; activation is the explicit, idempotent
# user action `oskar setup` (audit 2026-09-13, ticket 32).

HELPER := daemon/target/release/oskar-daemon
DESTDIR ?=

PLUGIN_RUNTIME := Panel.qml BarWidget.qml Keyboard.qml HelperLink.qml PasteChords.qml KeyboardLayout.js \
	KeyboardSession.js ModifierReducer.js Config.js Theme.qml \
	CursorPolicy.js CursorPolicy.qml LayoutDevices.js SettleGuard.js \
	EmojiPage.qml EmojiPage.js EmojiCatalog.js TextGlyphs.js \
	LanguageControl.js HoldColumn.js SocketWatch.js Dwell.js \
	InputProfile.js \
	UiStrings.js \
	ClipboardPaste.js HoverTooltip.qml KeyClickSound.qml \
	ChordAcks.js ShareQueue.js PasteFlow.js \
	SettingsPopover.qml SettingsColorRow.qml SettingsColorEditor.qml \
	SettingsConfirmChip.qml SettingsResetChip.qml DragLine.qml \
	SettingsPlacement.js manifest.json

.PHONY: build check stage install

build:
	cargo build --release --locked --manifest-path daemon/Cargo.toml

check: build
	./tools/run-tests.sh

# The packaged unit differs from the source-install unit in exactly one
# line: ExecStart points at the packaged helper instead of %h/.local.
# The transform lives here so systemd/oskar.service stays the one
# reviewed source.
stage: build
	install -Dm755 bin/oskar "$(DESTDIR)/usr/bin/oskar"
	install -Dm755 "$(HELPER)" \
		"$(DESTDIR)/usr/lib/oskar/oskar-daemon"
	install -Dm644 systemd/oskar.service \
		"$(DESTDIR)/usr/lib/systemd/user/oskar.service.tmp"
	sed 's|^ExecStart=.*|ExecStart=/usr/lib/oskar/oskar-daemon|' \
		"$(DESTDIR)/usr/lib/systemd/user/oskar.service.tmp" \
		> "$(DESTDIR)/usr/lib/systemd/user/oskar.service"
	rm "$(DESTDIR)/usr/lib/systemd/user/oskar.service.tmp"
	@# Runtime plugin payload: symlink-free, dev files excluded — the same
	@# set a published checkout validates against.
	set -e; for f in $(PLUGIN_RUNTIME); do \
		install -Dm644 "$$f" "$(DESTDIR)/usr/share/oskar/plugin/$$f"; done
	install -Dm644 LICENSE "$(DESTDIR)/usr/share/licenses/oskar/LICENSE"
	install -Dm644 third_party/emoji/LICENSE \
		"$(DESTDIR)/usr/share/licenses/oskar/emoji-data-LICENSE"
	install -Dm644 -t "$(DESTDIR)/usr/share/oskar/plugin/assets" assets/*.svg

install: stage
	@echo "staged into DESTDIR='$(DESTDIR)' (no system paths touched)"
