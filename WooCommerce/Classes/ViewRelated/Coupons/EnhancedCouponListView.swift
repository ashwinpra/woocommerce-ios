import SwiftUI

struct EnhancedCouponListView: UIViewControllerRepresentable {
    let siteID: Int64

    class Coordinator {
        var parentObserver: NSKeyValueObservation?
        var rightBarButtonItemsObserver: NSKeyValueObservation?
    }

    /// This is a UIKit solution for fixing Navigation Title and Bar Button Items ignored in NavigationView.
    /// This solution doesn't require making internal changes to the destination `UIViewController`
    /// and should be called once, when wrapped.
    /// Solution proposed here: https://stackoverflow.com/a/68567095/7241994
    ///
    func makeUIViewController(context: Self.Context) -> EnhancedCouponListViewController {
        let viewController = EnhancedCouponListViewController(siteID: siteID)
        context.coordinator.parentObserver = viewController.observe(\.parent, changeHandler: { vc, _ in
            vc.parent?.navigationItem.title = vc.title
            vc.parent?.navigationItem.rightBarButtonItems = vc.navigationItem.rightBarButtonItems
        })

        // This fixes the issue when `rightBarButtonItem` is updated in `CouponListViewController`,
        // the hosting controller should be updated to reflect the change.
        context.coordinator.rightBarButtonItemsObserver = viewController.observe(\.navigationItem.rightBarButtonItems, changeHandler: { vc, _ in
            vc.parent?.navigationItem.rightBarButtonItems = vc.navigationItem.rightBarButtonItems
        })
        return viewController
    }

    func updateUIViewController(_ uiViewController: EnhancedCouponListViewController, context: Context) {
        // nothing to do here
    }

    func makeCoordinator() -> Self.Coordinator { Coordinator() }
}
