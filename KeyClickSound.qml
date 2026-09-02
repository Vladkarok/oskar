import QtMultimedia

// The key click itself. The sound is the freedesktop sound theme's event
// sound rather than a bundled sample — no asset to ship, no taste to defend —
// and it is played in-process through QtMultimedia: a spawned process per
// keystroke is the wtype mistake again (decisions §1). The file is resolved
// once by the panel through the sound theme's own XDG search paths; this
// component only holds the effect.
//
// Loaded by Panel.qml behind a Loader so a system without qt6-multimedia
// loses only the click and not the keyboard: a failed import would otherwise
// take the whole panel down with it.
SoundEffect {
    // Absolute path of the theme file to play, as resolved by the panel.
    // Empty means "not resolved yet"; the loader stays inactive until a real
    // path exists, so play() is only ever called with a source present.
    property string filePath: ""

    source: filePath === "" ? "" : "file://" + filePath
}
