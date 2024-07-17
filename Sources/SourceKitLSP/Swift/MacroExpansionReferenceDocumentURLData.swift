//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import LanguageServerProtocol

/// Represents url of macro expansion reference document as follows:
/// `sourcekit-lsp://swift-macro-expansion/LaCb-LcCd.swift?sourceFileURL=&fromLine=&fromColumn=&toLine=&toColumn=&bufferName=`
///
/// Here,
///  - `LaCb-LcCd.swift`, the `displayName`, represents where the macro will expand to or
/// replace in the source file (i.e. `macroExpansionEditRange`)
///  - `sourceFileURL` denoting the URL of the source file
///  - `fromLine`, `fromColumn`, `toLine`, `toColumn` represents the cursor's `selectionRange`
///  - `bufferName` denotes the buffer name of the specific macro expansion edit
package struct MacroExpansionReferenceDocumentURLData {
  package var sourceFileURL: URL
  package var selectionRange: Range<Position>
  package var bufferName: String
  package var macroExpansionEditRange: Range<Position>?

  package init(
    macroExpansionEditRange: Range<Position>,
    sourceFileURL: URL,
    selectionRange: Range<Position>,
    bufferName: String
  ) {
    self.sourceFileURL = sourceFileURL
    self.selectionRange = selectionRange
    self.bufferName = bufferName
    self.macroExpansionEditRange = macroExpansionEditRange
  }

  private var displayName: String {
    if let macroExpansionEditRange {
      "L\(macroExpansionEditRange.lowerBound.line + 1)C\(macroExpansionEditRange.lowerBound.utf16index + 1)-L\(macroExpansionEditRange.upperBound.line + 1)C\(macroExpansionEditRange.upperBound.utf16index + 1).swift"
    } else {
      ""
    }
  }

  private var queryItems: [URLQueryItem]? {
    get {
      let queryItems = [
        URLQueryItem(name: Parameters.sourceFilePath, value: sourceFileURL.path(percentEncoded: false)),
        URLQueryItem(name: Parameters.fromLine, value: String(selectionRange.lowerBound.line)),
        URLQueryItem(name: Parameters.fromColumn, value: String(selectionRange.lowerBound.utf16index)),
        URLQueryItem(name: Parameters.toLine, value: String(selectionRange.upperBound.line)),
        URLQueryItem(name: Parameters.toColumn, value: String(selectionRange.upperBound.utf16index)),
        URLQueryItem(name: Parameters.bufferName, value: bufferName),
      ]

      return queryItems
    }
  }

  package var url: URL {
    get throws {
      var components = URLComponents()
      components.scheme = "sourcekit-lsp"
      components.host = "swift-macro-expansion"
      components.path = "/\(displayName)"
      components.queryItems = queryItems

      guard let url = components.url else {
        throw ReferenceDocumentURLError(
          description: "Unable to create URL for macro expansion reference document"
        )
      }

      return url
    }
  }

  package init(from url: URL) throws {
    guard url.scheme == "sourcekit-lsp" else {
      throw ReferenceDocumentURLError(description: "Invalid scheme for reference document")
    }

    guard url.host(percentEncoded: false) == "swift-macro-expansion" else {
      throw ReferenceDocumentURLError(
        description: "Invalid document type for macro expansion reference document"
      )
    }

    guard let urlComponents = URLComponents(string: url.absoluteString),
      let queryItems = urlComponents.queryItems,
      let sourceFilePath = queryItems.first { $0.name == Parameters.sourceFilePath }?.value,
      let fromLine = Int(queryItems.first { $0.name == Parameters.fromLine }?.value ?? ""),
      let fromColumn = Int(queryItems.first { $0.name == Parameters.fromColumn }?.value ?? ""),
      let toLine = Int(queryItems.first { $0.name == Parameters.toLine }?.value ?? ""),
      let toColumn = Int(queryItems.first { $0.name == Parameters.toColumn }?.value ?? ""),
      let bufferName = queryItems.first { $0.name == Parameters.bufferName }?.value
    else {
      throw ReferenceDocumentURLError(
        description: "Unable to parse URL into its components"
      )
    }

    guard let sourceFileURL = URL(string: "file://\(sourceFilePath)") else {
      throw ReferenceDocumentURLError(
        description: "Unable to parse source file url"
      )
    }

    self.sourceFileURL = sourceFileURL
    self.selectionRange =
      Position(line: fromLine, utf16index: fromColumn)..<Position(line: toLine, utf16index: toColumn)
    self.bufferName = bufferName
  }

  package func sourceDocument() -> DocumentURI {
    DocumentURI(sourceFileURL)
  }

  struct Parameters {
    static let sourceFilePath = "sourceFilePath"
    static let fromLine = "fromLine"
    static let fromColumn = "fromColumn"
    static let toLine = "toLine"
    static let toColumn = "toColumn"
    static let bufferName = "bufferName"
  }
}
