import Foundation

/// When an animated scene should be drawing frames. A scene redrawing 15 to 30 times a second costs a third of a core, so it only runs while somebody can
/// see it change: the window is in front, the person has touched the Mac in the last minute and a half, and the scene has something to show.
/// Protection, tamper monitoring and recovery do not depend on any scene; this only decides whether pixels are redrawn.
public enum SceneActivity {
    /// Seconds without keyboard or mouse input after which the scene stops redrawing; it resumes with the next input.
    public static let awayAfter: TimeInterval = 90
    /// How many times the "next step" marker pulses when it appears. A marker that pulses forever redraws every frame for as long as the window is open.
    public static let pulseCycles = 3
    public static func animates(windowActive: Bool, held: Bool, idleSeconds: TimeInterval, reduceMotion: Bool) -> Bool {
        windowActive && !held && !reduceMotion && idleSeconds < awayAfter
    }
}
