import Combine
import Foundation
import struct Yosemite.StoreProfilerAnswers

/// View model for `StoreCreationSellingStatusQuestionView`, an optional profiler question about store selling status in the store creation flow.
final class StoreCreationSellingStatusQuestionViewModel: StoreCreationProfilerQuestionViewModel, ObservableObject {
    typealias SellingStatus = StoreProfilerAnswers.SellingStatus

    let topHeader: String = Localization.header

    let title: String = Localization.title

    let subtitle: String = Localization.subtitle

    /// Question content.
    let sellingStatuses: [SellingStatus] = [.justStarting, .alreadySellingButNotOnline, .alreadySellingOnline]

    @Published private(set) var selectedStatus: SellingStatus?

    /// Set to `true` when the user selects the selling status as "I am already selling online".
    @Published private(set) var isAlreadySellingOnline: Bool = false

    private let onContinue: (StoreCreationSellingStatusAnswer?) -> Void
    private let onSkip: () -> Void

    init(onContinue: @escaping (StoreCreationSellingStatusAnswer?) -> Void,
         onSkip: @escaping () -> Void) {
        self.onContinue = onContinue
        self.onSkip = onSkip

        $selectedStatus
            .map { $0 == .alreadySellingOnline }
            .assign(to: &$isAlreadySellingOnline)
    }
}

extension StoreCreationSellingStatusQuestionViewModel: OptionalStoreCreationProfilerQuestionViewModel {
    func continueButtonTapped() {
        guard let selectedStatus else {
            return onSkip()
        }
        guard selectedStatus != .alreadySellingOnline else {
            // Handled in `StoreCreationSellingPlatformsQuestionViewModel`.
            return
        }
        onContinue(.init(sellingStatus: selectedStatus, sellingPlatforms: nil))
    }

    func skipButtonTapped() {
        onSkip()
    }
}

extension StoreCreationSellingStatusQuestionViewModel {
    /// Called when a selling status option is selected.
    func selectStatus(_ status: SellingStatus) {
        selectedStatus = status
    }
}

extension StoreCreationSellingStatusQuestionViewModel.SellingStatus {
    var description: String {
        switch self {
        case .justStarting:
            return NSLocalizedString(
                "I am just starting to sell",
                comment: "Option in the store creation selling status question."
            )
        case .alreadySellingButNotOnline:
            return NSLocalizedString(
                "I am selling offline",
                comment: "Option in the store creation selling status question."
            )
        case .alreadySellingOnline:
            return NSLocalizedString(
                "I am already selling online",
                comment: "Option in the store creation selling status question."
            )
        }
    }
}

private extension StoreCreationSellingStatusQuestionViewModel {
    enum Localization {
        static let header = NSLocalizedString(
            "About your store",
            comment: "Header of the store creation profiler question about the store selling status."
        )
        static let title = NSLocalizedString(
            "Which one of these best describes you?",
            comment: "Title of the store creation profiler question about the store selling status."
        )
        static let subtitle = NSLocalizedString(
            "Let us know where you are in your commerce journey so that we can tailor your Woo experience for you.",
            comment: "Subtitle of the store creation profiler question about the store selling status."
        )
    }
}
