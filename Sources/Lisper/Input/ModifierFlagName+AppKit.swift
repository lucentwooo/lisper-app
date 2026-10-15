// Sources/Lisper/Input/ModifierFlagName+AppKit.swift
import AppKit
import LisperKit

extension ModifierFlagName {
    /// The device-INDEPENDENT AppKit flag for this modifier. Left and Right variants share
    /// one flag, so this can only answer "is SOME control key down", never which one.
    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .function: return .function
        case .command:  return .command
        case .option:   return .option
        case .control:  return .control
        case .shift:    return .shift
        }
    }
}
