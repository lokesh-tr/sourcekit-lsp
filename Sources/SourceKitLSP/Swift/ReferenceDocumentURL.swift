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

/// A Reference Document is a document whose url scheme is `sourcekit-lsp:` and whose content can only be retrieved
/// using `GetReferenceDocumentRequest`. The enum represents a specific type of reference document and its
/// associated value represents the data necessary to generate the document's contents and its url
///
/// The `url` will be of the form: `sourcekit-lsp://<document-type>/<display-name>?<parameters>`
/// Here,
///  - The `<document-type>` denotes the kind of the content present in the reference document
///  - The `<parameters>` denotes the parameter-value pairs such as "p1=v1&p2=v2&..." needed to generate
/// the content of the reference document.
///  - The `<display-name>` is the displayed file name of the reference document. It doesn't involve in generating
/// the content of the reference document.
package enum ReferenceDocumentURL {
  case macroExpansion(MacroExpansionReferenceDocumentURLData)

  var url: URL {
    get throws {
      switch self {
      case let .macroExpansion(data):
        return try data.url
      }
    }
  }

  init(from uri: DocumentURI) throws {
    guard let urlString = uri.stringValue.removingPercentEncoding, let url = URL(string: urlString) else {
      throw ReferenceDocumentURLError(description: "Unable to parse URL from document URI")
    }

    try self.init(from: url)
  }

  init(from url: URL) throws {
    guard url.scheme == "sourcekit-lsp" else {
      throw ReferenceDocumentURLError(description: "Invalid Scheme for reference document")
    }

    if let macroExpansionURLData = try? MacroExpansionReferenceDocumentURLData(from: url) {
      self = .macroExpansion(macroExpansionURLData)
    } else {
      throw ReferenceDocumentURLError(description: "Invalid document type / data in url for reference document")
    }
  }

  /// Creates the `DocumentURI` of the source file, using which the reference document is generated, and returns it.
  /// - Returns: The `DocumentURI` of the source file
  func sourceDocument() -> DocumentURI {
    switch self {
    case let .macroExpansion(data):
      return data.sourceDocument()
    }
  }
}

package struct ReferenceDocumentURLError: Error, CustomStringConvertible {
  package var description: String

  init(description: String) {
    self.description = description
  }
}
