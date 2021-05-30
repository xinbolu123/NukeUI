// The MIT License (MIT)
//
// Copyright (c) 2015-2021 Alexander Grebenyuk (github.com/kean).

import Foundation
import Nuke

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if canImport(Gifu)
import Gifu
#endif

#warning("should it be based on UIView instead?")
#warning("how will animated image rendering work?")
public final class LazyImageView: _PlatformBaseView {

    #warning("need this?")
    public enum ImageType {
        case success, placeholder, failure
    }

    public func setTransition(_ transition: Any, for type: ImageType) {
        #warning("implement")
    }

    #if os(iOS) || os(tvOS)

    /// Set a custom content mode to be used for each image type (placeholder, success,
    /// failure).
    public func setContentMode(_ contentMode: UIView.ContentMode, for type: ImageType = .success) {
        #warning("impl")
    }

    #endif

    #warning("other options like managing priority and auto-retrying")

    // MARK: Placeholder View

    #if os(macOS)
    /// An image to be shown while the request is in progress.
    public var placeholderImage: NSImage? { didSet { setPlaceholderImage(placeholderImage) } }

    /// A view to be shown while the request is in progress. For example, can be a spinner.
    public var placeholderView: NSView? { didSet { setPlaceholderView(placeholderView) } }
    #else
    /// An image to be shown while the request is in progress.
    public var placeholderImage: UIImage? { didSet { setPlaceholderImage(placeholderImage) } }

    /// A view to be shown while the request is in progress. For example, can be a spinner.
    public var placeholderView: UIView? { didSet { setPlaceholderView(placeholderView) } }
    #endif

    /// `.fill` by default.
    public var placeholderViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != placeholderViewPosition, placeholderView != nil else { return }
            setNeedsUpdateConstraints()
        }
    }

    private var placeholderViewConstraints: [NSLayoutConstraint] = []

    // MARK: Failure View

    #if os(macOS)
    /// An image to be shown if the request fails.
    public var failureImage: NSImage? { didSet { setFailureImage(failureView) } }

    /// A view to be shown if the request fails.
    public var failureView: NSView? { didSet { setFailureView(failureView) } }
    #else
    /// An image to be shown if the request fails.
    public var failureImage: UIImage? { didSet { setFailureImage(failureImage) } }

    /// A view to be shown if the request fails.
    public var failureView: UIView? { didSet { setFailureView(failureView) } }
    #endif

    /// `.fill` by default.
    public var failureViewPosition: SubviewPosition = .fill {
        didSet {
            guard oldValue != failureViewPosition, failureView != nil else { return }
            setNeedsUpdateConstraints()
        }
    }

    private var failureViewConstraints: [NSLayoutConstraint] = []

    // MARK: Underlying Views

    #if os(macOS)
    /// Returns an underlying image view.
    public let imageView = NSImageView()
    #else
    /// Returns an underlying image view.
    public let imageView = UIImageView()
    #endif

    #if canImport(Gifu)
    /// Returns an underlying animated image view used for rendering animated images.
    public var animatedImageView: GIFImageView {
        if let animatedImageView = _animatedImageView {
            return animatedImageView
        }
        let animatedImageView = GIFImageView()
        _animatedImageView = animatedImageView
        return animatedImageView
    }

    private var _animatedImageView: GIFImageView?
    #endif

    // MARK: Managing Image Tasks

    /// Sets the priority of the image task. The priorit can be changed
    /// dynamically. `nil` by default.
    public var priority: ImageRequest.Priority? {
        didSet {
            if let priority = self.priority {
                imageTask?.priority = priority
            }
        }
    }

    /// Current image task.
    public var imageTask: ImageTask?

    /// The pipeline to be used for download. `shared` by default.
    public var pipeline: ImagePipeline = .shared

    // MARK: Callbacks

    /// Gets called when the request is started.
    public var onStarted: ((_ task: ImageTask) -> Void)?

    /// Gets called when the request progress is updated.
    public var onProgress: ((_ response: ImageResponse?, _ completed: Int64, _ total: Int64) -> Void)?

    /// Gets called when the request is completed.
    public var onFinished: ((_ result: Result<ImageResponse, ImagePipeline.Error>) -> Void)?

    // MARK: Other Options

    /// `true` by default. If disabled, progressive image scans will be ignored.
    public var isProgressiveImageRenderingEnabled = true

    /// `true` by default. If disabled, animated image rendering will be disabled.
    public var isAnimatedImageRenderingEnabled = true

    /// `true` by default. If enabled, the image view will be cleared before the
    /// new download is started.
    public var isPrepareForReuseEnabled = true

    // MARK: Initializers

    public override init(frame: CGRect) {
        super.init(frame: frame)
        didInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        didInit()
    }

    private func didInit() {
        addSubview(imageView)
        imageView.pinToSuperview()
    }

    #warning("rework this")
    public var source: ImageRequestConvertible? {
        didSet {
            load(source)
        }
    }

    public override func updateConstraints() {
        super.updateConstraints()

        updatePlaceholderViewConstraints()
        updateFailureViewConstraints()
    }

    /// Cancels current request and prepares the view for reuse.
    public func prepareForReuse() {
        cancel()

        placeholderView?.isHidden = true
        failureView?.isHidden = true
        _animatedImageView?.image = nil
        imageView.image = nil
    }

    /// Cancels current request.
    public func cancel() {
        imageTask?.cancel()
        imageTask = nil
    }

    // MARK: Loading

    /// Loads an image with the given request.
    private func load(_ request: ImageRequestConvertible?) {
        assert(Thread.isMainThread, "Must be called from the main thread")

        cancel()

        if isPrepareForReuseEnabled {
            prepareForReuse()
        }

        guard var request = request?.asImageRequest() else {
            let result: Result<ImageResponse, ImagePipeline.Error> = .failure(.dataLoadingFailed(URLError(.unknown)))
            handle(result, isFromMemory: true)
            onFinished?(result)
            return
        }

        // Quick synchronous memory cache lookup.
        if let image = pipeline.cache[request] {
            display(image, true, .success)
            if !image.isPreview { // Final image was downloaded
                onFinished?(.success(ImageResponse(container: image, cacheType: .memory)))
                return
            }
        }

        if let priority = self.priority {
            request.priority = priority
        }

        placeholderView?.isHidden = false

        let task = pipeline.loadImage(
            with: request,
            queue: .main,
            progress: { [weak self] response, completedCount, totalCount in
                guard let self = self else { return }
                if self.isProgressiveImageRenderingEnabled, let response = response {
                    self.placeholderView?.isHidden = true
                    self.display(response.container, false, .success)
                }
                self.onProgress?(response, completedCount, totalCount)
            },
            completion: { [weak self] result in
                #warning("temo")
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
                    guard let self = self else { return }
                    self.handle(result, isFromMemory: false)
                    self.onFinished?(result)
                }
            }
        )
        imageTask = task
        onStarted?(task)
    }

    // MARK: Handling Responses

    private func handle(_ result: Result<ImageResponse, ImagePipeline.Error>, isFromMemory: Bool) {
        placeholderView?.isHidden = true

        switch result {
        case let .success(response):
            display(response.container, isFromMemory, .success)
        case .failure:
            failureView?.isHidden = false
        }
        self.imageTask = nil
    }

    #warning("do we need response type here?")
    private func display(_ container: Nuke.ImageContainer, _ isFromMemory: Bool, _ response: ImageType) {
        // TODO: Add support for animated transitions and other options
        #if canImport(Gifu)
        if isAnimatedImageRenderingEnabled, let data = container.data, container.type == .gif {
            if animatedImageView.superview == nil {
                insertSubview(animatedImageView, belowSubview: imageView)
                animatedImageView.pinToSuperview()
            }
            animatedImageView.animate(withGIFData: data)
            visibleView = .animated
        } else {
            imageView.image = container.image
            visibleView = .regular
        }
        #else
        imageView.image = container.image
        #endif
    }

    var visibleView: ContentViewType = .regular {
        didSet {
            switch visibleView {
            case .regular:
                imageView.isHidden = false
                #if canImport(Gifu)
                animatedImageView.isHidden = true
                #endif
            case .animated:
                imageView.isHidden = true
                #if canImport(Gifu)
                animatedImageView.isHidden = false
                #endif
            }
        }
    }

    enum ContentViewType {
        case regular, animated
    }

    public enum SubviewPosition {
        /// Center in the superview.
        case center

        /// Fill the superview.
        case fill
    }

    // MARK: Private (Placeholder View)

    private func setPlaceholderImage(_ placeholderImage: _PlatformImage?) {
        guard let placeholderImage = placeholderImage else {
            placeholderView = nil
            return
        }
        placeholderView = _PlatformImageView(image: placeholderImage)
    }

    private func setPlaceholderView(_ view: _PlatformBaseView?) {
        if let previousView = placeholderView {
            previousView.removeFromSuperview()
        }
        if let newView = view {
            addSubview(newView)
            setNeedsUpdateConstraints()
            #if os(iOS) || os(tvOS)
            if let spinner = newView as? UIActivityIndicatorView {
                spinner.startAnimating()
            }
            #endif
        }
    }

    private func updatePlaceholderViewConstraints() {
        NSLayoutConstraint.deactivate(placeholderViewConstraints)

        if let placeholderView = self.placeholderView {
            switch placeholderViewPosition {
            case .center: placeholderViewConstraints = placeholderView.centerInSuperview()
            case .fill: placeholderViewConstraints = placeholderView.pinToSuperview()
            }
        }
    }

    // MARK: Private (Failure View)

    private func setFailureImage(_ failureImage: _PlatformImage?) {
        guard let failureImage = failureImage else {
            failureView = nil
            return
        }
        failureView = _PlatformImageView(image: failureImage)
    }

    private func setFailureView(_ view: _PlatformBaseView?) {
        if let previousView = failureView {
            previousView.removeFromSuperview()
        }
        if let newView = view {
            addSubview(newView)
            setNeedsUpdateConstraints()
        }
    }

    private func updateFailureViewConstraints() {
        NSLayoutConstraint.deactivate(failureViewConstraints)

        if let failureView = self.failureView {
            switch failureViewPosition {
            case .center: failureViewConstraints = failureView.centerInSuperview()
            case .fill: failureViewConstraints = failureView.pinToSuperview()
            }
        }
    }
}
