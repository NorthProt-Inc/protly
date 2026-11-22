@_exported import Foundation
@MainActor public protocol UITextDocumentProxy: AnyObject {
  var documentContextBeforeInput: String? { get }
  var documentContextAfterInput: String? { get }
  var selectedText: String? { get }
  var hasText: Bool { get }
  func adjustTextPosition(byCharacterOffset offset: Int)
  func deleteBackward()
  func insertText(_ text: String)
}
