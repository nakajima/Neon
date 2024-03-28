#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSwift
import SwiftTreeSitter
import Neon
import NSUI

final class TextViewController: NSUIViewController {
	let textView = NSUITextView(usingTextLayoutManager: false)
	let highlighter: TextViewHighlighter

	init() {
		// enable non-continguous layout for TextKit 1
		if textView.textLayoutManager == nil {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
			textView.layoutManager?.allowsNonContiguousLayout = true
#else
			textView.layoutManager.allowsNonContiguousLayout = true
#endif
		}

		self.highlighter = try! Self.makeHighlighter(for: textView)

		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	private static func makeHighlighter(for textView: NSUITextView) throws -> TextViewHighlighter {
		let regularFont = NSUIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
		let boldFont = NSUIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
		let italicDescriptor = regularFont.fontDescriptor.withSymbolicTraits(.traitItalic)

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
		let italicFont = NSUIFont(descriptor: italicDescriptor, size: 16) ?? regularFont
#elseif canImport(UIKit)
		let italicFont = NSUIFont(descriptor: italicDescriptor ?? regularFont.fontDescriptor, size: 16)
#endif

		// Set the default styles. This is applied by stock `NSTextStorage`s during
		// so-called "attribute fixing" when you type, and we emulate that as
		// part of the highlighting process in `TextViewSystemInterface`.
		textView.typingAttributes = [
			.foregroundColor: NSUIColor.darkGray,
			.font: regularFont,
		]

		let provider: TokenAttributeProvider = { token in
			return switch token.name {
			case let keyword where keyword.hasPrefix("keyword"): [.foregroundColor: NSUIColor.red, .font: boldFont]
			case "comment", "spell": [.foregroundColor: NSUIColor.green, .font: italicFont]
			// Note: Default is not actually applied to unstyled/untokenized text.
			default: [.foregroundColor: NSUIColor.blue, .font: regularFont]
			}
		}

		// this is doing both synchronous language initialization everything, but TreeSitterClient supports lazy loading for embedded languages
		let markdownConfig = try! LanguageConfiguration(
			tree_sitter_markdown(),
			name: "Markdown"
		)

		let markdownInlineConfig = try! LanguageConfiguration(
			tree_sitter_markdown_inline(),
			name: "MarkdownInline",
			bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
		)

		let swiftConfig = try! LanguageConfiguration(
			tree_sitter_swift(),
			name: "Swift"
		)

		let highlighterConfig = TextViewHighlighter.Configuration(
			languageConfiguration: swiftConfig, // the root language
			attributeProvider: provider,
			languageProvider: { name in
				print("embedded language: ", name)

				switch name {
				case "swift":
					return swiftConfig
				case "markdown_inline":
					return markdownInlineConfig
				default:
					return nil
				}
			},
			locationTransformer: { _ in nil }
		)

		return try TextViewHighlighter(textView: textView, configuration: highlighterConfig)
	}

	override func loadView() {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
		let scrollView = NSScrollView()

		scrollView.hasVerticalScroller = true
		scrollView.documentView = textView
		
		let max = CGFloat.greatestFiniteMagnitude

		textView.minSize = NSSize.zero
		textView.maxSize = NSSize(width: max, height: max)
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = true

		textView.isRichText = false  // Discards any attributes when pasting.

		self.view = scrollView

		// this has to be done after the textview has been embedded in the scrollView if
		// it wasn't that way on creation
		highlighter.observeEnclosingScrollView()
#else
		self.view = textView
#endif

		regularTest()
	}

	func regularTest() {
		let url = Bundle.main.url(forResource: "test", withExtension: "code")!
		let content = try! String(contentsOf: url)

		textView.text = content
	}

	func doBigTest() {
		let url = Bundle.main.url(forResource: "big_test", withExtension: "md")!
		let content = try! String(contentsOf: url)

		textView.text = content

		DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
			let range = NSRange(location: content.utf16.count, length: 0)

			self.textView.scrollRangeToVisible(range)
		}
	}
}