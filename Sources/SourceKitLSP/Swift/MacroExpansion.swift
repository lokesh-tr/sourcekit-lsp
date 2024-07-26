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

import Crypto
import Foundation
import LanguageServerProtocol
import SKLogging
import SourceKitD

/// Detailed information about the result of a macro expansion operation.
///
/// Wraps the information returned by sourcekitd's `semantic_refactoring`
/// request, such as the necessary macro expansion edits.
struct MacroExpansion: RefactoringResponse {
  /// The title of the refactoring action.
  var title: String

  /// The URI of the file where the macro is used
  var uri: DocumentURI

  /// The resulting array of `RefactoringEdit` of a semantic refactoring request
  var edits: [RefactoringEdit]

  init(title: String, uri: DocumentURI, refactoringEdits: [RefactoringEdit]) {
    self.title = title
    self.uri = uri
    self.edits = refactoringEdits.compactMap { refactoringEdit in
      if refactoringEdit.bufferName == nil && !refactoringEdit.newText.isEmpty {
        logger.fault("Unable to retrieve some parts of the expansion")
        return nil
      }

      return refactoringEdit
    }
  }
}

extension SwiftLanguageService {
  /// Handles the `ExpandMacroCommand`.
  ///
  /// Makes a `PeekDocumentsRequest` or `ShowDocumentRequest`, containing the
  /// location of each macro expansion, to the client depending on whether the
  /// client supports the `experimental["workspace/peekDocuments"]` capability.
  ///
  /// - Parameters:
  ///   - expandMacroCommand: The `ExpandMacroCommand` that triggered this request.
  func expandMacro(
    _ expandMacroCommand: ExpandMacroCommand
  ) async throws {
    guard let sourceKitLSPServer else {
      // `SourceKitLSPServer` has been destructed. We are tearing down the
      // language server. Nothing left to do.
      throw ResponseError.unknown("Connection to the editor closed")
    }

    guard let sourceFileURL = expandMacroCommand.textDocument.uri.fileURL else {
      throw ResponseError.unknown("Given URI is not a file URL")
    }

    let expansion = try await self.refactoring(expandMacroCommand)

    var completeExpansionFileContent = ""
    var completeExpansionDirectoryName = ""

    var macroExpansionReferenceDocumentURLs: [ReferenceDocumentURL] = []
    for macroEdit in expansion.edits {
      if let bufferName = macroEdit.bufferName {
        let macroExpansionReferenceDocumentURLData =
          ReferenceDocumentURL.macroExpansion(
            MacroExpansionReferenceDocumentURLData(
              macroExpansionEditRange: macroEdit.range,
              sourceFileURL: sourceFileURL,
              selectionRange: expandMacroCommand.positionRange,
              bufferName: bufferName
            )
          )

        macroExpansionReferenceDocumentURLs.append(macroExpansionReferenceDocumentURLData)

        completeExpansionDirectoryName += "\(bufferName)-"

        let editContent =
          """
          // \(sourceFileURL.lastPathComponent) @ \(macroEdit.range.lowerBound.line + 1):\(macroEdit.range.lowerBound.utf16index + 1) - \(macroEdit.range.upperBound.line + 1):\(macroEdit.range.upperBound.utf16index + 1)
          \(macroEdit.newText)


          """
        completeExpansionFileContent += editContent
      } else if !macroEdit.newText.isEmpty {
        logger.fault("Unable to retrieve some parts of macro expansion")
      }
    }

    if case .dictionary(let experimentalCapabilities) = self.capabilityRegistry.clientCapabilities.experimental,
      case .bool(true) = experimentalCapabilities["workspace/peekDocuments"],
      case .bool(true) = experimentalCapabilities["workspace/getReferenceDocument"]
    {
      let expansionURIs = try macroExpansionReferenceDocumentURLs.map {
        return DocumentURI(try $0.url)
      }
      Task {
        let req = PeekDocumentsRequest(
          uri: expandMacroCommand.textDocument.uri,
          position: expandMacroCommand.positionRange.lowerBound,
          locations: expansionURIs
        )

        let response = await orLog("Sending PeekDocumentsRequest to Client") {
          try await sourceKitLSPServer.sendRequestToClient(req)
        }

        if let response, !response.success {
          logger.error("client refused to peek macro")
        }
      }
    } else {
      // removes superfluous newline
      if completeExpansionFileContent.hasSuffix("\n\n") {
        completeExpansionFileContent.removeLast()
      }

      if completeExpansionDirectoryName.hasSuffix("-") {
        completeExpansionDirectoryName.removeLast()
      }

      var completeExpansionFilePath =
        self.generatedMacroExpansionsPath.appendingPathComponent(
          Insecure.MD5.hash(
            data: Data(completeExpansionDirectoryName.utf8)
          )
          .map { String(format: "%02hhx", $0) }  // maps each byte of the hash to its hex equivalent `String`
          .joined()
        )

      do {
        try FileManager.default.createDirectory(
          at: completeExpansionFilePath,
          withIntermediateDirectories: true
        )
      } catch {
        throw ResponseError.unknown(
          "Failed to create directory for complete macro expansion at path: \(completeExpansionFilePath.path)"
        )
      }

      completeExpansionFilePath =
        completeExpansionFilePath.appendingPathComponent(sourceFileURL.lastPathComponent)
      do {
        try completeExpansionFileContent.write(to: completeExpansionFilePath, atomically: true, encoding: .utf8)
      } catch {
        throw ResponseError.unknown(
          "Unable to write complete macro expansion to file path: \"\(completeExpansionFilePath.path)\""
        )
      }

      let completeMacroExpansionFilePath = completeExpansionFilePath

      Task {
        let req = ShowDocumentRequest(uri: DocumentURI(completeMacroExpansionFilePath))

        let response = await orLog("Sending ShowDocumentRequest to Client") {
          try await sourceKitLSPServer.sendRequestToClient(req)
        }

        if let response, !response.success {
          logger.error("client refused to show document for macro expansion")
        }
      }
    }
  }

  func expandMacro(macroExpansionURLData: inout MacroExpansionReferenceDocumentURLData) async throws -> String {
    guard let sourceKitLSPServer = self.sourceKitLSPServer else {
      // `SourceKitLSPServer` has been destructed. We are tearing down the
      // language server. Nothing left to do.
      throw ResponseError.unknown("Connection to the editor closed")
    }

    let expandMacroCommand = ExpandMacroCommand(
      positionRange: macroExpansionURLData.selectionRange,
      textDocument: TextDocumentIdentifier(macroExpansionURLData.sourceDocument())
    )

    let expansion = try await self.refactoring(expandMacroCommand)

    guard
      let macroExpansionEdit = expansion.edits.filter({
        $0.bufferName == macroExpansionURLData.bufferName
      }).only
    else {
      throw ResponseError.unknown("Macro Expansion Edit doesn't Exist")
    }

    macroExpansionURLData.macroExpansionEditRange = macroExpansionEdit.range

    let content = macroExpansionEdit.newText

    return content
  }
}
