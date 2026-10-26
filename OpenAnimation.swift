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
// v72: the whole open animation now runs through Swift's native API —
// the cover fade and the handwriting reveal moved here too, with the
// same timing as the old ObjC drivers. The glyph setup (CoreText
// paths) stays in Tweak.xm; only the animation driving moved.
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

    // v72: cover fade — 0.15s ease-out, removes the cover when done.
    // Called from popCompletion, after the recompute.
    @objc public static func fadeCover(_ cover: UIView) {
        let animator = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) {
            cover.alpha = 0
        }
        animator.addCompletion { [weak animator] _ in
            if let animator = animator { activeAnimators.remove(animator) }
            cover.removeFromSuperview()
        }
        activeAnimators.insert(animator)
        animator.startAnimation()
    }

    // v72: handwriting reveal — each glyph's clip widens over 0.22s,
    // staggered 0.12s apart (one animator per clip, started with
    // afterDelay, so the stagger is exact), then the container fades
    // over 0.15s at 1.78s and is removed (~1.93s total). Same timing
    // as the old ObjC version, only the driver changes.
    @objc public static func animateHandwriting(container: UIView, clips: [UIView], widths: [NSNumber]) {
        for (i, clip) in clips.enumerated() {
            guard i < widths.count else { break }
            let targetWidth = CGFloat(truncating: widths[i])
            let frame = clip.frame
            let animator = UIViewPropertyAnimator(duration: 0.22, timingParameters: UICubicTimingParameters(animationCurve: .easeOut))
            animator.addAnimations {
                clip.frame = CGRect(x: frame.origin.x, y: frame.origin.y, width: targetWidth, height: frame.size.height)
            }
            animator.addCompletion { [weak animator] _ in
                if let animator = animator { activeAnimators.remove(animator) }
            }
            activeAnimators.insert(animator)
            animator.startAnimation(afterDelay: Double(i) * 0.12)
        }
        let fade = UIViewPropertyAnimator(duration: 0.15, curve: .easeOut) {
            container.alpha = 0
        }
        fade.addCompletion { [weak fade] _ in
            if let fade = fade { activeAnimators.remove(fade) }
            container.removeFromSuperview()
        }
        activeAnimators.insert(fade)
        fade.startAnimation(afterDelay: 1.78)
    }
}
