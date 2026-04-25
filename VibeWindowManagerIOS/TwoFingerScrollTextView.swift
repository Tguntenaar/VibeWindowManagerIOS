//
//  TwoFingerScrollTextView.swift
//  VibeWindowManagerIOS
//
//  1-finger UIPan on the readout *superview* (same touch routing as the UITextView) → window move.
//  2-finger pan on the UITextView (min/max touches 2) → scroll. Both fingers must land on the
//  scroll view; the old “back layer + hitTest pass-through” split touch 1 vs 2 and broke 2f scroll.
//

import SwiftUI
import UIKit

struct TwoFingerScrollTextView: UIViewRepresentable {
    var text: String
    var textColor: UIColor
    var font: UIFont
    var scrollToBottomOnTextChange: Bool
    var onMoveBegin: () -> Void
    var onMoveChange: (CGFloat, CGFloat) -> Void
    var onMoveEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveBegin: onMoveBegin,
            onMoveChange: onMoveChange,
            onMoveEnd: onMoveEnd
        )
    }

    func makeUIView(context: Context) -> TmuxReadoutContainerView {
        let c = context.coordinator
        let v = TmuxReadoutContainerView(
            textView: c.textView,
            moveTarget: c,
            moveAction: #selector(Coordinator.handleWindowMovePan(_:))
        )
        c.bindCallbacks(
            onMoveBegin: onMoveBegin,
            onMoveChange: onMoveChange,
            onMoveEnd: onMoveEnd
        )
        return v
    }

    func updateUIView(_ view: TmuxReadoutContainerView, context: Context) {
        let c = context.coordinator
        c.bindCallbacks(
            onMoveBegin: onMoveBegin,
            onMoveChange: onMoveChange,
            onMoveEnd: onMoveEnd
        )
        let tv = c.textView
        tv.textColor = textColor
        tv.font = font
        if tv.text != text {
            tv.text = text
            if scrollToBottomOnTextChange {
                let token = c.nextScrollToken()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [token] in
                    guard c.tokenMatches(token) else { return }
                    let ns = (tv.text ?? "") as NSString
                    let len = ns.length
                    guard len > 0 else { return }
                    tv.scrollRangeToVisible(NSRange(location: max(0, len - 1), length: 1))
                    tv.layoutIfNeeded()
                    tv.flashScrollIndicators()
                }
            } else {
                DispatchQueue.main.async {
                    tv.layoutIfNeeded()
                    tv.flashScrollIndicators()
                }
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let textView: UITextView
        private var onMoveBegin: () -> Void
        private var onMoveChange: (CGFloat, CGFloat) -> Void
        private var onMoveEnd: () -> Void

        private var scrollToken: UInt = 0
        private var moveArmed: Bool
        private var startLocation: CGPoint

        init(
            onMoveBegin: @escaping () -> Void,
            onMoveChange: @escaping (CGFloat, CGFloat) -> Void,
            onMoveEnd: @escaping () -> Void
        ) {
            self.onMoveBegin = onMoveBegin
            self.onMoveChange = onMoveChange
            self.onMoveEnd = onMoveEnd
            self.textView = UITextView()
            self.moveArmed = false
            self.startLocation = .zero
            super.init()
            Self.configureTextViewForTwoFingerScroll(textView)
        }

        fileprivate static func configureTextViewForTwoFingerScroll(_ tv: UITextView) {
            tv.isEditable = false
            tv.isScrollEnabled = true
            tv.isSelectable = true
            tv.backgroundColor = .clear
            tv.textContainerInset = .init(top: 2, left: 2, bottom: 2, right: 2)
            tv.textContainer.lineFragmentPadding = 0
            tv.isMultipleTouchEnabled = true
            // Right-edge scroll track (fades in while scrolling; light style on dark tmux panel).
            tv.showsVerticalScrollIndicator = true
            tv.showsHorizontalScrollIndicator = false
            tv.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
            tv.indicatorStyle = .white
            let pan = tv.panGestureRecognizer
            pan.maximumNumberOfTouches = 2
            pan.minimumNumberOfTouches = 2
        }

        /// 1f move pan on `TmuxTextFrontView` only for single-touch; 2+ fingers go to the text view (2f scroll).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
            (event.allTouches?.count ?? 0) <= 1
        }

        func bindCallbacks(
            onMoveBegin: @escaping () -> Void,
            onMoveChange: @escaping (CGFloat, CGFloat) -> Void,
            onMoveEnd: @escaping () -> Void
        ) {
            self.onMoveBegin = onMoveBegin
            self.onMoveChange = onMoveChange
            self.onMoveEnd = onMoveEnd
        }

        fileprivate func nextScrollToken() -> UInt {
            scrollToken &+= 1
            return scrollToken
        }

        fileprivate func tokenMatches(_ t: UInt) -> Bool { t == scrollToken }

        @objc fileprivate func handleWindowMovePan(_ g: UIPanGestureRecognizer) {
            // Match SwiftUI DragGesture(minimumDistance: 6) + .global: translation from drag start, window space
            let ref = g.view?.window
            let t = g.translation(in: ref)
            switch g.state {
            case .began:
                startLocation = g.location(in: ref)
                moveArmed = false
            case .changed:
                if !moveArmed {
                    let loc = g.location(in: ref)
                    let dx0 = loc.x - startLocation.x
                    let dy0 = loc.y - startLocation.y
                    if (dx0 * dx0 + dy0 * dy0) < Self.moveMinDistanceSquared {
                        return
                    }
                    moveArmed = true
                    onMoveBegin()
                }
                onMoveChange(t.x, t.y)
            case .ended, .cancelled, .failed:
                if moveArmed {
                    onMoveEnd()
                }
                moveArmed = false
            default:
                break
            }
        }

        private static var moveMinDistance: CGFloat { 6 } // same as MirrorGestureConstants.moveMinDistance
        private static var moveMinDistanceSquared: CGFloat { moveMinDistance * moveMinDistance }
    }
}

// MARK: - Container (superview: 1f move; subview: 2f scroll)

final class TmuxReadoutContainerView: UIView {
    private var front: TmuxTextFrontView

    init(
        textView: UITextView,
        moveTarget: TwoFingerScrollTextView.Coordinator,
        moveAction: Selector
    ) {
        self.front = TmuxTextFrontView()
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        addSubview(front)
        front.embed(textView: textView)

        let movePan = UIPanGestureRecognizer(target: moveTarget, action: moveAction)
        movePan.minimumNumberOfTouches = 1
        movePan.maximumNumberOfTouches = 1
        movePan.delegate = moveTarget
        // Attach to the readout *superview* of the UITextView so the same subview still receives
        // all touches; UIGestureRecognizer on an ancestor also participates for touches in descendants.
        front.addGestureRecognizer(movePan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        front.frame = bounds
    }
}

/// Wraps the `UITextView` full-bleed. Default `hitTest` (no custom routing).
final class TmuxTextFrontView: UIView {
    private var textView: UITextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func embed(textView: UITextView) {
        if self.textView === textView, textView.superview == self { return }
        self.textView?.removeFromSuperview()
        self.textView = textView
        addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
