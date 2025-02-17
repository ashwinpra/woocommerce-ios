import SwiftUI
import Yosemite

/// View model for `FreeTrialSurveyView`
///
final class FreeTrialSurveyViewModel: ObservableObject {
    @Published private(set) var selectedAnswer: SurveyAnswer?
    @Published var otherReasonSpecified: String = ""
    /// Triggered when the user taps Cancel or Submits the survey.
    let onClose: () -> Void

    private let analytics: Analytics
    private let source: FreeTrialSurveyCoordinator.Source
    private let inAppPurchaseManager: InAppPurchasesForWPComPlansProtocol
    private let localNotificationScheduler: LocalNotificationScheduler
    private let stores: StoresManager

    init(source: FreeTrialSurveyCoordinator.Source,
         onClose: @escaping () -> Void,
         stores: StoresManager = ServiceLocator.stores,
         analytics: Analytics = ServiceLocator.analytics,
         pushNotesManager: PushNotesManager = ServiceLocator.pushNotesManager,
         inAppPurchaseManager: InAppPurchasesForWPComPlansProtocol = InAppPurchasesForWPComPlansManager()) {
        self.source = source
        self.onClose = onClose
        self.stores = stores
        self.analytics = analytics
        self.localNotificationScheduler = .init(pushNotesManager: pushNotesManager, stores: stores)
        self.inAppPurchaseManager = inAppPurchaseManager
    }

    var answers: [SurveyAnswer] {
        SurveyAnswer.allCases
    }

    var feedbackSelected: Bool {
        guard let selectedAnswer else {
            return false
        }

        if selectedAnswer == .otherReasons {
            return otherReasonSpecified.isNotEmpty
        }

        return true
    }

    func selectAnswer(_ answer: SurveyAnswer) {
        selectedAnswer = answer
    }

    func submitFeedback() {
        guard let selectedAnswer else {
            return
        }

        if selectedAnswer == .stillExploring {
            scheduleLocalNotificationAfterThreeDays()
        }

        analytics.track(event: .FreeTrialSurvey.surveySent(source: source,
                                                           surveyOption: selectedAnswer.rawValue,
                                                           freeText: otherReasonSpecified.isNotEmpty ? otherReasonSpecified : nil))
        onClose()
    }

    enum SurveyAnswer: String, CaseIterable {
        case stillExploring = "still_exploring"
        case comparingWithOtherPlatforms = "comparing_with_other_platforms"
        case priceIsSignificantFactor = "price_is_significant_factor"
        case collectiveDecision = "collective_decision"
        case otherReasons = "other_reasons"

        var text: String {
            switch self {
            case .stillExploring:
                return Localization.stillExploring
            case .comparingWithOtherPlatforms:
                return Localization.comparingWithOtherPlatforms
            case .priceIsSignificantFactor:
                return Localization.priceIsSignificantFactor
            case .collectiveDecision:
                return Localization.collectiveDecision
            case .otherReasons:
                return Localization.otherReasons
            }
        }

        private enum Localization {
            static let stillExploring = NSLocalizedString(
                "I am still exploring and assessing the features and benefits of the app.",
                comment: "Text for Free trial survey answer."
            )
            static let comparingWithOtherPlatforms = NSLocalizedString(
                "I am evaluating and comparing your service with others on the market",
                comment: "Text for Free trial survey answer."
            )
            static let priceIsSignificantFactor = NSLocalizedString(
                "I find the price of the service to be a significant factor in my decision.",
                comment: "Text for Free trial survey answer."
            )
            static let collectiveDecision = NSLocalizedString(
                "I am part of a team, and we need to make the decision collectively.",
                comment: "Text for Free trial survey answer."
            )
            static let otherReasons = NSLocalizedString(
                "Other (please specify).",
                comment: "Placeholder text for Free trial survey."
            )
        }
    }
}

private extension FreeTrialSurveyViewModel {
    func scheduleLocalNotificationAfterThreeDays() {
        guard let site = stores.sessionManager.defaultSite,
              let triggerDateComponents = Date().adding(days: Constants.daysToAddForStillExploringNotification)?.dateAndTimeComponents() else {
            return
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDateComponents, repeats: false)
        Task {
            let iapAvailable = await inAppPurchaseManager.inAppPurchasesAreSupported()
            let notification = LocalNotification(scenario: .threeDaysAfterStillExploring(siteID: site.siteID),
                                                 userInfo: [LocalNotification.UserInfoKey.isIAPAvailable: iapAvailable])
            await localNotificationScheduler.schedule(notification: notification,
                                                      trigger: trigger,
                                                      remoteFeatureFlag: nil,
                                                      shouldSkipIfScheduled: true)
        }
    }

    enum Constants {
        static let daysToAddForStillExploringNotification = 3
    }
}
