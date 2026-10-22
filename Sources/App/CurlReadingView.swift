import SwiftUI
import UIKit

/// UIKit owns interactive curl progress. Reading position changes only after a completed turn.
struct CurlReadingView: UIViewControllerRepresentable {
    let text: NSAttributedString
    let ranges: [NSRange]
    let page: Int
    let paper: UIColor
    let onPage: (Int) -> Void
    let previousChapter: () -> Void
    let nextChapter: () -> Void
    let toggleChrome: () -> Void
    var contentInsets: UIEdgeInsets = .zero
    var title: String? = nil
    var ink: UIColor = .label

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        controller.isDoubleSided = false
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        controller.view.backgroundColor = paper
        context.coordinator.controller = controller
        controller.setViewControllers([context.coordinator.content(page)], direction: .forward, animated: false)
        // The full viewport owns configured tap zones. Keep native pan gestures only,
        // otherwise a left-edge tap can turn backward while the configured action turns forward.
        for gesture in controller.gestureRecognizers where gesture is UITapGestureRecognizer { gesture.isEnabled = false }
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.turning,
              (controller.viewControllers?.first as? CurlPageController)?.index != page else { return }
        let old = (controller.viewControllers?.first as? CurlPageController)?.index ?? page
        context.coordinator.turning = true
        controller.setViewControllers([context.coordinator.content(page)], direction: page >= old ? .forward : .reverse, animated: true) { _ in
            context.coordinator.turning = false
            // Fast taps can update the SwiftUI target during the native animation.
            let latest = context.coordinator.parent.page
            if latest != page, context.coordinator.parent.ranges.indices.contains(latest) {
                controller.setViewControllers([context.coordinator.content(latest)], direction: latest >= page ? .forward : .reverse, animated: false)
            }
        }
    }
    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        controller.delegate = nil; controller.dataSource = nil
        coordinator.controller = nil
    }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: CurlReadingView
        weak var controller: UIPageViewController?
        var turning = false
        init(_ parent: CurlReadingView) { self.parent = parent }
        func content(_ index: Int) -> CurlPageController {
            CurlPageController(index: index, text: parent.text,
                range: parent.ranges.indices.contains(index) ? parent.ranges[index] : nil,
                paper: parent.paper, boundary: index < 0 ? "上一章" : "下一章",
                contentInsets: parent.contentInsets, title: parent.title,
                footer: "\(index + 1) / \(parent.ranges.count)", ink: parent.ink)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? CurlPageController, current.index >= 0 else { return nil }
            return content(current.index - 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? CurlPageController, current.index < parent.ranges.count else { return nil }
            return content(current.index + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { turning = true }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            turning = false
            guard completed, let visible = pageViewController.viewControllers?.first as? CurlPageController else { return }
            if parent.ranges.indices.contains(visible.index) { parent.onPage(visible.index) }
            else {
                // Boundary callbacks may be a no-op at the beginning/end of the book.
                pageViewController.setViewControllers([content(parent.page)], direction: .forward, animated: false)
                if visible.index < 0 { parent.previousChapter() } else { parent.nextChapter() }
            }
        }
        func pageViewController(_ pageViewController: UIPageViewController, spineLocationFor orientation: UIInterfaceOrientation) -> UIPageViewController.SpineLocation { .min }
        @objc func tap(_ gesture: UITapGestureRecognizer) { if gesture.state == .ended { parent.toggleChrome() } }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            let fraction = touch.location(in: view).x / max(1, view.bounds.width)
            return !turning && fraction > 0.34 && fraction < 0.66
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

final class CurlPageController: UIViewController {
    let index: Int
    private let text: NSAttributedString
    private let range: NSRange?
    private let paper: UIColor
    private let boundary: String
    private let contentInsets: UIEdgeInsets
    private let heading: String?
    private let footer: String
    private let ink: UIColor
    private var drawing: CoreTextPage?
    private var headingLabel: UILabel?
    private var footerLabel: UILabel?
    init(index: Int, text: NSAttributedString, range: NSRange?, paper: UIColor, boundary: String,
         contentInsets: UIEdgeInsets = .zero, title: String? = nil, footer: String = "", ink: UIColor = .label) {
        self.index = index; self.text = text; self.range = range; self.paper = paper; self.boundary = boundary
        self.contentInsets = contentInsets; heading = title; self.footer = footer; self.ink = ink
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        if let range {
            let page = CoreTextPage()
            page.text = text; page.range = range; page.backgroundColor = paper; page.isOpaque = true
            page.isAccessibilityElement = true; page.accessibilityLabel = text.attributedSubstring(from: range).string
            let canvas = UIView(); canvas.backgroundColor = paper; canvas.isOpaque = true
            canvas.accessibilityIdentifier = "reader.curlCanvas"
            canvas.addSubview(page); drawing = page
            if let heading {
                let label = UILabel(); label.text = heading; label.font = .preferredFont(forTextStyle: .caption1)
                label.textColor = ink.withAlphaComponent(0.6); canvas.addSubview(label); headingLabel = label
            }
            if !footer.isEmpty {
                let label = UILabel(); label.text = footer; label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                label.textAlignment = .center; label.textColor = ink.withAlphaComponent(0.6)
                label.accessibilityIdentifier = "reader.pageIndicator"; canvas.addSubview(label); footerLabel = label
            }
            view = canvas
        } else {
            let label = UILabel(); label.text = boundary; label.textAlignment = .center
            label.backgroundColor = paper; label.textColor = .secondaryLabel; view = label
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let rect = view.bounds.inset(by: contentInsets)
        drawing?.frame = rect
        headingLabel?.frame = CGRect(x: rect.minX, y: rect.minY - 28, width: rect.width, height: 20)
        footerLabel?.frame = CGRect(x: rect.minX, y: rect.maxY + 8, width: rect.width, height: 18)
    }
}

#if DEBUG
extension CurlReadingView {
    @MainActor static func checkTurning() {
        Task { @MainActor in
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            var offsets: [Int] = [], boundaries = 0
            let parent = CurlReadingView(text: NSAttributedString(string: "第一页第二页"), ranges: [NSRange(location: 0, length: 3), NSRange(location: 3, length: 3)],
                page: 0, paper: .white, onPage: { offsets.append($0) }, previousChapter: { boundaries += 1 }, nextChapter: { boundaries += 1 }, toggleChrome: {},
                contentInsets: UIEdgeInsets(top: 70, left: 26, bottom: 60, right: 26), title: "章节标题")
            let coordinator = Coordinator(parent)
            let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
            coordinator.controller = controller; controller.dataSource = coordinator; controller.delegate = coordinator
            controller.setViewControllers([coordinator.content(0)], direction: .forward, animated: false)
            let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.isHidden = false
            controller.view.layoutIfNeeded()
            let first = controller.viewControllers?.first as? CurlPageController
            first?.view.layoutIfNeeded()
            let fullViewport = first?.view.bounds.width == controller.view.bounds.width && first?.view.bounds.height == controller.view.bounds.height
            let insetText = first?.view.subviews.first?.frame == first?.view.bounds.inset(by: parent.contentInsets)
            coordinator.pageViewController(controller, willTransitionTo: [coordinator.content(1)])
            coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
            let cancelledPreserved = offsets.isEmpty && boundaries == 0
            try? await Task.sleep(nanoseconds: 400_000_000)
            let animationCompleted = await withCheckedContinuation { continuation in
                controller.setViewControllers([coordinator.content(1)], direction: .forward, animated: true) { continuation.resume(returning: $0) }
            }
            coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            let advanced = offsets == [1]
            controller.setViewControllers([coordinator.content(2)], direction: .forward, animated: false)
            coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            let boundaryReset = boundaries == 1 && (controller.viewControllers?.first as? CurlPageController)?.index == 0
            let report: [String: Any] = ["status": cancelledPreserved && advanced && boundaryReset && animationCompleted && fullViewport && insetText ? "passed" : "failed",
                "fullViewport": fullViewport, "insetText": insetText,
                "cancelledPreserved": cancelledPreserved, "advanced": advanced, "boundaryReset": boundaryReset, "animationCompleted": animationCompleted]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: URL.documentsDirectory.appendingPathComponent("curl-check.json"), options: .atomic)
            }
            window.isHidden = true
        }
    }
}
#endif
