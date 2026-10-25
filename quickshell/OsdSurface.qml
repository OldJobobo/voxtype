// Voxtype on-screen display surface (Quickshell frontend).
//
// Renders a glassy card with:
//   - State icon + tint (recording / streaming / transcribing)
//   - Scrolling waveform of recent mic peaks (3-second window, 100 Hz)
//   - Peak meter bar with held-peak tick (-60 dB floor, color zones at
//     -12 and -3 dBFS to match the GTK4 and native frontends)
//
// Driven entirely from a parent-provided AudioBridge: the parent is
// expected to subscribe to AudioBridge once and pass it in via the
// `audio` property so the OsdSurface, EnginePicker, and MeetingControls
// share one sidecar process rather than each spawning their own.
//
// Visibility follows `daemonState` unless `osdSuppressed` is set or
// `activeOutput` is false: hidden when suppressed, off the active
// output, or idle/empty, shown otherwise. The component is layered as a WlrLayer.Overlay surface so
// it floats above all other windows without taking input focus.

import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "voxtype-shared" as VT

PanelWindow {
    id: panel

    /// Current daemon state: idle / recording / streaming / transcribing.
    /// Wired by the parent (typically from VT.StateReader.state).
    property string daemonState: "idle"

    /// Set while the in-flight recording was started with `--no-osd`. Wired by
    /// the parent from VT.StateReader.osdSuppressed. Keeps the surface hidden
    /// for tools that draw their own dictation UI, without touching the
    /// daemon's reported state.
    property bool osdSuppressed: false

    /// False on outputs that shouldn't show the HUD right now. Wired by
    /// the parent from the compositor's focused output; defaults to true
    /// so a standalone surface behaves as before.
    property bool activeOutput: true

    /// The audio bridge instance whose frameReceived signal drives the
    /// waveform. Passed in by the parent so it's shared with sibling
    /// widgets that also want VAD / peak data.
    property var audio: null

    /// Resolved style loader from VT.StyleLoader. Provides semantic colors,
    /// visual recipe layers, and optional custom QML package entry.
    property var style: null

    visible: !osdSuppressed && activeOutput && daemonState !== "idle" && daemonState !== ""
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    WlrLayershell.namespace: "voxtype-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Subtract the whole panel area from the input region, so pointer
    // events fall through to windows underneath instead of getting
    // eaten by the transparent fullscreen-anchored surface.
    mask: Region {
        intersection: Intersection.Subtract
        x: 0; y: 0
        width: panel.width
        height: panel.height
    }

    // Per-state tint, shared by icon + card border so a Hyprland user
    // can read the daemon's state from screen-edge color alone.
    readonly property color stateColor:
        daemonState === "recording"    ? panel._styleColor("recording", VT.Theme.recordingColor)
      : daemonState === "streaming"    ? panel._styleColor("streaming", VT.Theme.streamingColor)
      : daemonState === "transcribing" ? panel._styleColor("transcribing", VT.Theme.transcribingColor)
      :                                  panel._styleColor("idle", VT.Theme.idleColor)

    // Capacity of the waveform history: 3 s @ 100 Hz.
    readonly property int waveformColumns: Math.round(VT.Theme.waveformWindowSecs * 100)

    // Live meter state, written at audio rate (100 Hz) and read by the
    // renderer once per animation tick. A plain object mutated in place:
    // frames change no QML properties, so they trigger no bindings.
    // `ring` holds recent per-frame peaks (0.0..1.0), newest last. dBFS
    // values match src/osd/visual.rs's PeakHold.
    property var _meter: ({
        peak: 0, rms: 0, vad: false,
        peakDbfs: -120, heldDbfs: -120, lastTsMs: 0,
        ring: []
    })
    readonly property string customQmlUrl: _customQmlUrl()
    readonly property bool hasCustomQml: customQmlUrl.length > 0
    /// Set when the custom QML package fails to load, so the built-in
    /// surface can take over instead of leaving the OSD blank.
    property bool customQmlFailed: false
    /// True while a custom QML package is selected and loading/loaded.
    /// Every built-in element keys its visibility off this so a broken
    /// package falls back to the default card.
    readonly property bool customActive: hasCustomQml && !customQmlFailed
    // Smoothed on the renderer's tick, so decorations need no Behaviors.
    readonly property real voiceEnergy: recipeRenderer.voiceEnergy
    readonly property real orbHaloEnergy: recipeRenderer.haloEnergy
    readonly property bool recordingVisual: daemonState === "recording"

    onCustomQmlUrlChanged: customQmlFailed = false

    function _styleColor(role, fallback) {
        if (style && style.color) {
            return style.color(role, fallback);
        }
        return fallback;
    }

    function _styleLayout() {
        return style && style.config && style.config.layout
            ? style.config.layout
            : "compact";
    }

    function _stylePosition() {
        return style && style.config && style.config.position
            ? String(style.config.position)
            : "bottom-center";
    }

    function _styleMarginPx() {
        const value = style && style.config && style.config.margin_px !== undefined
            ? Number(style.config.margin_px)
            : VT.Theme.marginPx;
        return Math.max(0, value);
    }

    function _styleTopMargin() {
        const value = style && style.config && style.config.top_margin !== undefined
            ? Number(style.config.top_margin)
            : 0.85;
        return Math.max(0.0, Math.min(1.0, value));
    }

    function _frameConfig() {
        return style && style.config && style.config.frame
            ? style.config.frame
            : { "background": "background", "border": "state", "glow": true, "halo": true };
    }

    function _frameValue(key, fallback) {
        const frame = _frameConfig();
        const value = frame && frame[key] !== undefined ? String(frame[key]) : fallback;
        return value.length > 0 ? value : fallback;
    }

    function _frameBackgroundColor() {
        const value = _frameValue("background", "background");
        if (value === "none" || value === "transparent") return "transparent";
        return panel._styleColor(value, VT.Theme.bgColor);
    }

    function _frameBorderColor() {
        const value = _frameValue("border", "state");
        if (value === "none" || value === "transparent") return "transparent";
        if (value === "state") return panel.stateColor;
        return panel._styleColor(value, panel.stateColor);
    }

    function _frameBorderWidth() {
        const value = _frameValue("border", "state");
        return value === "none" || value === "transparent" ? 0 : 2;
    }

    function _frameGlowEnabled() {
        const frame = _frameConfig();
        return frame.glow === undefined ? true : !!frame.glow;
    }

    function _frameHaloEnabled() {
        const frame = _frameConfig();
        return frame.halo === undefined ? true : !!frame.halo;
    }

    function _cardWidth() {
        const layout = _styleLayout();
        if (layout === "wide") return Math.max(VT.Theme.defaultWidthPx, 560);
        if (layout === "minimal") return Math.min(VT.Theme.defaultWidthPx, 260);
        if (layout === "tile") return 176;
        if (layout === "orb") return 168;
        return VT.Theme.defaultWidthPx;
    }

    function _cardHeight() {
        const layout = _styleLayout();
        if (layout === "minimal") return 48;
        if (layout === "tile") return 176;
        if (layout === "orb") return 168;
        return 72;
    }

    function _cardRadius() {
        const layout = _styleLayout();
        if (layout === "orb") return Math.round(_cardWidth() / 2);
        if (layout === "tile") return 18;
        return VT.Theme.cornerRadius;
    }

    function _cardX() {
        const position = _stylePosition();
        const margin = _styleMarginPx();
        if (position.indexOf("left") >= 0) return margin;
        if (position.indexOf("right") >= 0) return Math.max(margin, panel.width - _cardWidth() - margin);
        return Math.max(margin, (panel.width - _cardWidth()) / 2);
    }

    function _cardY() {
        const position = _stylePosition();
        const margin = _styleMarginPx();
        if ((position === "top-left") || (position === "top-right")) return margin;
        if ((position === "bottom-left") || (position === "bottom-right")) {
            return Math.max(margin, panel.height - _cardHeight() - margin);
        }
        const y = panel.height * _styleTopMargin();
        return Math.max(margin, Math.min(panel.height - _cardHeight() - margin, y));
    }

    function _isBlockLayout() {
        const layout = _styleLayout();
        return layout === "tile" || layout === "orb" || layout === "custom";
    }

    function _isOrbLayout() {
        return _styleLayout() === "orb";
    }

    function _customQmlUrl() {
        if (style && style.customQmlUrl) {
            return style.customQmlUrl();
        }
        return "";
    }

    function _syncCustomItem() {
        if (!customLoader.item) return;
        if ("daemonState" in customLoader.item) customLoader.item.daemonState = daemonState;
        if ("audio" in customLoader.item) customLoader.item.audio = audio;
        if ("theme" in customLoader.item) customLoader.item.theme = style;
        if ("recipe" in customLoader.item) customLoader.item.recipe = style && style.config ? style.config.visual : null;
        if ("assetRoot" in customLoader.item) {
            customLoader.item.assetRoot = style && style.config ? style.config.asset_root || "" : "";
        }
    }

    function _resetMeters() {
        const m = _meter;
        m.peak = 0;
        m.rms = 0;
        m.vad = false;
        m.peakDbfs = -120;
        m.heldDbfs = -120;
        m.lastTsMs = 0;
        m.ring.length = 0;
        recipeRenderer.reset();
    }

    Connections {
        target: panel.audio
        // Hidden surfaces (idle, --no-osd, every output but the ones
        // showing) skip the 100 Hz frame work entirely.
        enabled: panel.audio !== null && panel.visible
        function onFrameReceived(peak, rms, vad, tsMs) {
            const m = panel._meter;
            m.peak = peak;
            m.rms = rms;
            m.vad = vad;

            // Newest peak on the right; drop the oldest when full.
            const r = m.ring;
            r.push(peak);
            if (r.length > panel.waveformColumns) {
                r.splice(0, r.length - panel.waveformColumns);
            }

            // dBFS from linear peak. Floor at -120 to match visual.rs's
            // PeakHold::held_dbfs sentinel for "effectively silent".
            const dbfs = peak > 0.0 ? 20 * Math.log10(peak) : -120;
            m.peakDbfs = dbfs;

            // Held-peak: snap up on a louder peak, otherwise decay at
            // peakDecayDbPerSec. dt comes from the frame timestamps so
            // a paused daemon (no frames) doesn't unrealistically decay
            // before we receive the next frame.
            const dt = (m.lastTsMs > 0 ? Math.max(0, tsMs - m.lastTsMs) : 10) / 1000;
            m.lastTsMs = tsMs;
            if (dbfs > m.heldDbfs) {
                m.heldDbfs = dbfs;
            } else {
                const decayed = m.heldDbfs - VT.Theme.peakDecayDbPerSec * dt;
                m.heldDbfs = decayed < -120 ? -120 : decayed;
            }
        }
        function onDisconnected() {
            panel._resetMeters();
        }
    }

    // Clear when the daemon's state moves out of recording so the
    // waveform doesn't show stale audio from the previous recording on
    // the next one.
    onDaemonStateChanged: {
        if (daemonState === "idle" || daemonState === "") {
            _resetMeters();
        }
        _syncCustomItem();
    }

    // A surface skips frames while hidden, so whatever it held is stale
    // when it reappears (focus moved here mid-recording, or a --no-osd
    // recording ended). Start clean rather than replaying old waveform
    // and decaying the held peak across the whole hidden interval.
    onVisibleChanged: {
        if (visible) {
            _resetMeters();
        }
    }

    onAudioChanged: _syncCustomItem()
    onStyleChanged: _syncCustomItem()

    Loader {
        id: customLoader
        anchors.fill: parent
        active: panel.customActive
        source: panel.hasCustomQml ? panel.customQmlUrl : ""
        onLoaded: panel._syncCustomItem()
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("voxtype OSD: failed to load custom QML, falling back to built-in surface:", source);
                panel.customQmlFailed = true;
            }
        }
    }

    // Glow source lives in the scene (hidden) rather than inline on the
    // MultiEffect property: an unparented item never joins the window's
    // scene graph and may not be rendered into the effect texture.
    Rectangle {
        id: frameGlowSource
        visible: false
        width: card.width
        height: card.height
        radius: card.radius
        color: "transparent"
        border.width: 2
        border.color: panel._styleColor("accent", panel.stateColor)
    }

    // Energy-driven values come pre-smoothed from the renderer's tick,
    // so they bind directly. Behaviors here would restart an animation
    // on every tick; only the recording fade-in/out animates.
    MultiEffect {
        id: frameGlow
        visible: !panel.customActive && panel._frameGlowEnabled() && !panel._isOrbLayout()
        anchors.centerIn: card
        width: frameGlowSource.width
        height: frameGlowSource.height
        source: frameGlowSource
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowHorizontalOffset: 0
        shadowVerticalOffset: 0
        shadowColor: panel._styleColor("accent", panel.stateColor)
        shadowOpacity: 0.18 + panel.voiceEnergy * 0.34
        shadowBlur: 0.68 + panel.voiceEnergy * 0.22
        shadowScale: 1.02 + panel.voiceEnergy * 0.055
        blurMax: 64
        opacity: panel.recordingVisual ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
    }

    Item {
        anchors.fill: parent
        visible: !panel.customActive && panel._frameHaloEnabled() && !panel._isOrbLayout()
        opacity: panel.recordingVisual ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Rectangle {
            id: frameHalo
            width: card.width + 3
            height: card.height + 3
            x: card.x - 1.5
            y: card.y - 1.5
            radius: card.radius + 1.5
            color: "transparent"
            border.color: panel._styleColor("accent", panel.stateColor)
            border.width: 1 + panel.voiceEnergy * 1.4
            opacity: 0.12 + panel.voiceEnergy * 0.28
        }
    }

    // Soft dark backdrop behind the orb: a static radial gradient that
    // only scales and fades with energy, so it never re-rasterizes.
    Item {
        id: orbBackdrop
        visible: !panel.customActive && panel._isOrbLayout()
        readonly property real maxOuter: card.width * 0.96
        x: card.x + card.width / 2 - maxOuter
        y: card.y + card.height / 2 + 8 - maxOuter
        width: maxOuter * 2
        height: maxOuter * 2
        opacity: panel.recordingVisual ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            opacity: 0.62 + panel.orbHaloEnergy * 0.16
            scale: (0.84 + panel.orbHaloEnergy * 0.12) / 0.96
            ShapePath {
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: orbBackdrop.maxOuter; centerY: orbBackdrop.maxOuter
                    centerRadius: orbBackdrop.maxOuter
                    focalX: orbBackdrop.maxOuter; focalY: orbBackdrop.maxOuter
                    focalRadius: orbBackdrop.maxOuter * 0.05
                    GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.54) }
                    GradientStop { position: 0.42; color: Qt.rgba(0, 0, 0, 0.58) }
                    GradientStop { position: 0.74; color: Qt.rgba(0, 0, 0, 0.18) }
                    GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.0) }
                }
                PathRectangle {
                    width: orbBackdrop.width
                    height: orbBackdrop.height
                    radius: orbBackdrop.maxOuter
                }
            }
        }
    }

    // Orb halo: one soft accent glow hugging the orb's edge that swells
    // and brightens with the voice. A static gradient, so energy changes
    // only move a transform and an opacity.
    Item {
        id: orbGlow
        visible: !panel.customActive && panel._isOrbLayout() && panel._frameHaloEnabled()
        readonly property real outer: card.width * 0.92
        readonly property real edge: (card.width / 2) / outer
        x: card.x + card.width / 2 - outer
        y: card.y + card.height / 2 - outer
        width: outer * 2
        height: outer * 2
        opacity: panel.recordingVisual ? 1.0 : 0.0
        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Shape {
            id: glowShape
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            readonly property color tint: panel._styleColor("accent", panel.stateColor)
            opacity: 0.30 + panel.orbHaloEnergy * 0.70
            scale: 0.90 + panel.orbHaloEnergy * 0.10
            ShapePath {
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: orbGlow.outer; centerY: orbGlow.outer; centerRadius: orbGlow.outer
                    focalX: orbGlow.outer; focalY: orbGlow.outer
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: orbGlow.edge * 0.96; color: "transparent" }
                    GradientStop { position: orbGlow.edge * 1.04; color: Qt.rgba(glowShape.tint.r, glowShape.tint.g, glowShape.tint.b, 0.42) }
                    GradientStop { position: orbGlow.edge + (1 - orbGlow.edge) * 0.45; color: Qt.rgba(glowShape.tint.r, glowShape.tint.g, glowShape.tint.b, 0.12) }
                    GradientStop { position: 1.0; color: "transparent" }
                }
                PathRectangle {
                    width: orbGlow.width
                    height: orbGlow.height
                    radius: orbGlow.outer
                }
            }
        }
    }

    Rectangle {
        id: card
        visible: !panel.customActive
        width: panel._cardWidth()
        height: panel._cardHeight()
        x: panel._cardX()
        y: panel._cardY()
        radius: panel._cardRadius()
        color: panel._frameBackgroundColor()
        border.width: panel._frameBorderWidth()
        border.color: panel._frameBorderColor()
        // Dim slightly between words. Smoothed on the renderer's tick: a
        // Behavior here would animate on every VAD flip, several times a
        // second, and keep the window redrawing at the display's full
        // refresh rate.
        opacity: (panel.recordingVisual && panel.audio && panel.audio.running)
                 ? 0.78 + 0.22 * recipeRenderer.voiceActivity : 1.0

        Row {
            anchors.fill: parent
            anchors.leftMargin: panel._isBlockLayout() ? 0 : VT.Theme.padding
            anchors.rightMargin: panel._isBlockLayout() ? 0 : VT.Theme.padding
            spacing: 10

            // Lifted toward the foreground: some theme palettes map the
            // state roles to dark, low-contrast colors.
            VT.StateIcon {
                visible: !panel._isBlockLayout()
                width: 28
                height: 22
                anchors.verticalCenter: parent.verticalCenter
                daemonState: panel.daemonState
                phase: recipeRenderer.phase
                color: Qt.tint(panel.stateColor, Qt.alpha(panel._styleColor("foreground", VT.Theme.textColor), 0.5))
            }

            Column {
                width: panel._isBlockLayout()
                    ? card.width
                    : card.width - 28 - 2 * VT.Theme.padding - 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Item {
                    width: parent.width
                    height: panel._isBlockLayout()
                        ? card.height
                        : Math.max(24, card.height - 2 * VT.Theme.padding)

                    VT.RecipeRenderer {
                        id: recipeRenderer
                        anchors.fill: parent
                        // Items inside a hidden PanelWindow still report
                        // visible, so the renderer can't see a --no-osd
                        // hide on its own.
                        active: panel.visible
                        style: panel.style
                        meter: panel._meter
                        daemonState: panel.daemonState
                        waveformColumns: panel.waveformColumns
                        waveformGain: VT.Theme.waveformGain
                        meterFloorDbfs: VT.Theme.meterFloorDbfs
                    }
                }
            }
        }
    }
}
