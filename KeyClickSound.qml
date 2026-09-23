import QtMultimedia

// The key click itself. Plays the freedesktop sound theme's event sound
// in-process through QtMultimedia rather than spawning a process per
// keystroke. The panel resolves the theme file once through the sound
// theme's search paths and transcodes it to PCM (SoundEffect plays
// uncompressed WAV only); this component only holds the result.
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
