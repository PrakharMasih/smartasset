// Mapping decoder failures onto the job error classes (plan §6.6): transient / file-corrupt / unsupported / permission.
import AVFoundation
import CoreBridge
import Foundation

enum MediaFailure: Error {
    case unsupported(String)
    case corrupt(String)
    case thumbnail(String)
}

enum ErrorClassifier {
    static func classify(_ error: Error) -> (ErrorClass, String) {
        if let failure = error as? MediaFailure {
            switch failure {
            case .unsupported(let m): return (.unsupported, m)
            case .corrupt(let m): return (.fileCorrupt, m)
            case .thumbnail(let m): return (.fileCorrupt, m)
            }
        }
        let ns = error as NSError
        let message = ns.localizedDescription
        switch ns.domain {
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return (.permission, message)
            case NSFileReadCorruptFileError: return (.fileCorrupt, message)
            case NSFileReadUnsupportedSchemeError: return (.unsupported, message)
            // The file vanished or the disk hiccuped: the scanner decides whether it is missing.
            default: return (.transient, message)
            }
        case NSPOSIXErrorDomain:
            switch ns.code {
            case Int(EACCES), Int(EPERM): return (.permission, message)
            default: return (.transient, message)
            }
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: ns.code) {
            case .fileFormatNotRecognized, .decoderNotFound, .decoderTemporarilyUnavailable, .formatUnsupported,
                 .noCompatibleAlternatesForExternalDisplay:
                return (.unsupported, message)
            case .failedToLoadMediaData, .fileFailedToParse, .contentIsUnavailable, .noDataCaptured, .unknown:
                return (.fileCorrupt, message)
            default:
                return (.transient, message)
            }
        default:
            return (.transient, message)
        }
    }
}
