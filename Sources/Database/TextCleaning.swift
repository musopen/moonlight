// TextCleaning.swift
//
// Tidies text that people type or that comes from song tags before Moonlight stores or writes it.
// Invisible control characters (such as line breaks pasted into a one-line box) are turned into
// spaces, so a name or title can't break the layout of a playlist file or the app's lists.
// Ordinary letters, accents, emoji and spaces are left exactly as they are.

import Foundation

extension String {
    /// The text on a single line: each run of line breaks, tabs or other control characters
    /// becomes one space. Ordinary spaces are kept; callers trim the ends if they need to.
    var singleLineText: String { cleanedText(keepingLineBreaks: false) }

    /// The text with control characters replaced by spaces. With `keepingLineBreaks`, line breaks
    /// are kept (Windows and old Mac line endings become "\n") for fields such as comments.
    func cleanedText(keepingLineBreaks: Bool) -> String {
        var result = String.UnicodeScalarView()
        var previousWasReplaced = false
        var previousWasCarriageReturn = false
        for scalar in unicodeScalars {
            defer { previousWasCarriageReturn = scalar == "\r" }
            if keepingLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                if scalar == "\n", previousWasCarriageReturn { continue }
                result.append("\n")
                previousWasReplaced = false
            } else if scalar.isControlOrLineBreak {
                if !previousWasReplaced { result.append(" ") }
                previousWasReplaced = true
            } else {
                result.append(scalar)
                previousWasReplaced = false
            }
        }
        return String(result)
    }
}

private extension Unicode.Scalar {
    var isControlOrLineBreak: Bool {
        properties.generalCategory == .control
            || properties.generalCategory == .lineSeparator
            || properties.generalCategory == .paragraphSeparator
    }
}
