import QtMultimedia

// The key click itself. The sound is the freedesktop sound theme's event
// sound rather than a bundled sample — no asset to ship, no taste to defend —
// and it is played in-process through QtMultimedia: a spawned process per
// keystroke is the wtype mistake again (decisions §1). The panel resolves the
// theme file once through the sound theme's own search paths and transcodes
// it to PCM for this effect (SoundEffect plays uncompressed WAV only); this
// component only holds the result.
//
// Loaded by Panel.qml behind a Loader so a system without qt6-multimedia
// loses only the click and not the keyboard: a failed import would otherwise
// take the whole panel down with it.
SoundEffect {
    // Absolute path of the PCM copy of the theme's event sound, as prepared
    // by the panel. Empty means "not resolved yet"; the loader stays inactive
    // until a real path exists, so play() is only ever called with a source
    // present.
    property string filePath: ""

    source: filePath === "" ? "" : "file://" + filePath
}
