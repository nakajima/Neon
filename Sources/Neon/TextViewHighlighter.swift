import Foundation

import RangeState
import TreeSitterClient
import SwiftTreeSitter
import SwiftTreeSitterLayer

#if os(macOS) && !targetEnvironment(macCatalyst)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif

#if os(macOS) || os(iOS) || os(visionOS)
public enum TextViewHighlighterError: Error {
	case noTextStorage
}

extension TextView {
#if os(macOS) && !targetEnvironment(macCatalyst)
	func getTextStorage() throws -> NSTextStorage {
		guard let storage = textStorage else {
			throw TextViewHighlighterError.noTextStorage
		}

		return storage
	}
#else
	func getTextStorage() throws -> NSTextStorage {
		textStorage
	}
#endif
}

extension TextView {
	var textString: String {
#if os(macOS) && !targetEnvironment(macCatalyst)
		self.string
#else
		self.text
#endif
	}
}

// This is probably a terrible idea lol
extension Never: TextSystemInterface {
	public var content: NSTextStorage { .init() }
	public func applyStyles(for application: TokenApplication) {}
	public var visibleSet: IndexSet {	.init() }
}

/// A class that can connect `NSTextView`/`UITextView` to `TreeSitterClient`
///
/// This class is a minimal implementation that can help perform highlighting
/// for a TextView. The created instance will become the delegate of the
/// view's `NSTextStorage`.
@MainActor
public final class TextViewHighlighter<Interface: TextSystemInterface> {
	private typealias Styler = TextSystemStyler<Interface>

	public struct Configuration {
		public let languageConfiguration: LanguageConfiguration
		public let attributeProvider: TokenAttributeProvider
		public let languageProvider: LanguageLayer.LanguageProvider
		public let locationTransformer: Point.LocationTransformer
		public let textSystemInterface: Interface?

		public init(
			languageConfiguration: LanguageConfiguration,
			languageProvider: @escaping LanguageLayer.LanguageProvider = { _ in nil },
			locationTransformer: @escaping Point.LocationTransformer,
			textSystemInterface: Interface
		) {
			self.languageConfiguration = languageConfiguration
			self.languageProvider = languageProvider
			self.locationTransformer = locationTransformer
			self.textSystemInterface = textSystemInterface

			// Provided by the interface
			self.attributeProvider = { _ in [:] }
		}
	}

	public let textView: TextView

	private let configuration: Configuration
	private let styler: Styler
	private let interface: Interface
	private let client: TreeSitterClient
	private let buffer = RangeInvalidationBuffer()
	private let storageDelegate = TextStorageDelegate()

#if os(iOS) || os(visionOS)
	private var frameObservation: NSKeyValueObservation?
	private var lastVisibleRange = NSRange.zero
#endif

	public init(
		textView: TextView,
		configuration: Configuration
	) throws {
		self.textView = textView
		self.configuration = configuration
		self.interface = configuration.textSystemInterface ?? TextViewSystemInterface(textView: textView, attributeProvider: configuration.attributeProvider) as! Interface
		self.client = try TreeSitterClient(
			rootLanguageConfig: configuration.languageConfiguration,
			configuration: .init(
				languageProvider: configuration.languageProvider,
				contentProvider: { LanguageLayer.Content(string: textView.textString, limit: $0) },
				lengthProvider: { [interface] in interface.content.currentLength },
				invalidationHandler: { [buffer] in buffer.invalidate(.set($0)) },
				locationTransformer: configuration.locationTransformer
			)
		)

		// this level of indirection is necessary so when the TextProvider is accessed it always uses the current version of the content
		let tokenProvider = client.tokenProvider(with: { [textView] in
			textView.textString.predicateTextProvider($0, $1)
		})

		self.styler = TextSystemStyler(
			textSystem: interface,
			tokenProvider: tokenProvider
		)

		buffer.invalidationHandler = { [styler] in
			styler.invalidate($0)

			styler.validate()
		}

		storageDelegate.willChangeContent = { [buffer, client] range, _ in
			// a change happening, start buffering invalidations
			buffer.beginBuffering()

			client.willChangeContent(in: range)
		}

		storageDelegate.didChangeContent = { [buffer, client, styler] range, delta in
			let adjustedRange = NSRange(location: range.location, length: range.length - delta)

			client.didChangeContent(in: adjustedRange, delta: delta)
			styler.didChangeContent(in: adjustedRange, delta: delta)

			// At this point in mutation processing, it is unsafe to apply style changes. Ideally, we'd have a hook so we can know when it is ok. But, no such system exists for stock TextKit 1/2. So, instead we just let the runloop turn. This is *probably* safe, if the text does not change again, but can also result in flicker.
			DispatchQueue.main.async {
				buffer.endBuffering()
			}

		}

		try textView.getTextStorage().delegate = storageDelegate

		observeEnclosingScrollView()

		invalidate(.all)
	}

	/// Perform manual invalidation on the underlying highlighter
	public func invalidate(_ target: RangeTarget) {
		buffer.invalidate(target)
	}

	/// Inform the client that calls to languageConfiguration may change.
	public func languageConfigurationChanged(for name: String) {
		client.languageConfigurationChanged(for: name)
	}

	@objc private func visibleContentChanged(_ notification: NSNotification) {
		styler.visibleContentDidChange()
	}
}

extension TextViewHighlighter.Configuration where Interface == Never {
	public init(
		languageConfiguration: LanguageConfiguration,
		attributeProvider: @escaping TokenAttributeProvider,
		languageProvider: @escaping LanguageLayer.LanguageProvider = { _ in nil },
		locationTransformer: @escaping Point.LocationTransformer
	) {
		self.languageConfiguration = languageConfiguration
		self.attributeProvider = attributeProvider
		self.languageProvider = languageProvider
		self.locationTransformer = locationTransformer
		self.textSystemInterface = nil
	}
}

extension TextViewHighlighter {
	public func observeEnclosingScrollView() {
#if os(macOS) && !targetEnvironment(macCatalyst)
		guard let scrollView = textView.enclosingScrollView else {
			print("warning: there is no enclosing scroll view")
			return
		}

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(visibleContentChanged(_:)),
			name: NSView.frameDidChangeNotification,
			object: scrollView
		)

		NotificationCenter.default.addObserver(
			self,
			selector: #selector(visibleContentChanged(_:)),
			name: NSView.boundsDidChangeNotification,
			object: scrollView.contentView
		)
#elseif os(iOS) || os(visionOS)
		self.frameObservation = textView.observe(\.contentOffset) { [weak self] view, _ in
			MainActor.backport.assumeIsolated {
				guard let self = self else { return }

				self.lastVisibleRange = self.textView.visibleTextRange

				DispatchQueue.main.async {
					guard self.textView.visibleTextRange == self.lastVisibleRange else { return }

					self.styler.visibleContentDidChange()
				}
			}
		}
#endif
	}


}

#endif
