import UIKit

// v69: the open pop's spring, driven by Swift's native animation API
// (UIViewPropertyAnimator + UISpringTimingParameters). The rest of the
// open animation (anchor setup, bottom cover, handwriting reveal) stays
// in Tweak.xm; this class only runs the pop itself. It is exposed to
// the ObjC runtime under a fixed name so Tweak.xm can find it with
// objc_getClass, with no generated-header import needed. If the class
// is ever missing at runtime, Tweak.xm falls back to its ObjC spring.
// v70: animators are held in a set, one per in-flight pop. v69 kept
// a single static slot, so a second window opening within ~0.6s
// released the first window's animator mid-flight and its completion
// (anchor restore, chrome re-sync, cover fade) never ran.
@objc(MultitaskFloatOpenAnimator)
public final class MultitaskFloatOpenAnimator: NSObject {
    // Every in-flight animator is held here until its own completion
    // runs. A single slot cannot hold two overlapping pops (two
    // windows opened in quick succession); a set can.
    private static var activeAnimators: Set<UIViewPropertyAnimator> = []

    @objc public static func animatePop(
        view: UIView,
        fromScale: CGFloat,
        finalRadius: CGFloat,
        completion: @escaping () -> Void
    ) {
        // Start state (same as the caller sets in Tweak.xm): scaled
        // down around the tap anchor, transparent.
        view.transform = CGAffineTransform(scaleX: fromScale, y: fromScale)
        view.alpha = 0
        // Native spring: mass 1, stiffness 170, damping 20. Damping
        // ratio is about 0.77, so it settles with a slight overshoot
        // instead of the old 0.3s stiff spring. Duration 0 lets the
        // spring physics decide the settle time (about 0.6s).
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: 170,
            damping: 20,
            initialVelocity: .zero
        )
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        animator.addAnimations {
            view.alpha = 1
            view.transform = .identity
            view.layer.cornerRadius = finalRadius
        }
        animator.addCompletion { [weak animator] _ in
            if let animator = animator { activeAnimators.remove(animator) }
            completion()
        }
        activeAnimators.insert(animator)
        animator.startAnimation()
    }
}
