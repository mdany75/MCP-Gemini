import Foundation

/// Écriture sur stdout ou stderr sans exception : `FileHandle.write` lève une exception Objective-C (le
/// serveur meurt sans nettoyage) quand l'autre bout du tube est fermé et que SIGPIPE est ignoré.
public enum StdioWriter {
    /// `false` si tout n'a pas pu être écrit (tube fermé…).
    @discardableResult
    public static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }
}
