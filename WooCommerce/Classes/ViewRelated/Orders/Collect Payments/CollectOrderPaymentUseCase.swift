import Foundation
import Combine
import Yosemite
import MessageUI
import WooFoundation
import protocol Storage.StorageManagerType
//TODO: Move to alertprovider (and ideally, remove from this target or translate through Yosemite)
import enum Hardware.CardReaderServiceError
import enum Hardware.UnderlyingError

/// Protocol to abstract the `CollectOrderPaymentUseCase`.
/// Currently only used to facilitate unit tests.
///
protocol CollectOrderPaymentProtocol {
    /// Starts the collect payment flow.
    ///
    /// - Parameter using: We specify a discovery method to allow us to choose between Tap to Pay and Bluetooth readers, which have distinct connection flows.
    /// - Parameter onCompleted: Closure Invoked after the flow has been totally completed.
    /// - Parameter onCancel: Closure invoked after the flow is cancelled
    /// - Parameter onFailure: Closure invoked when there is an error in the flow
    /// - Parameter onPaymentCompletion: Closure invoked after any payment completes, but while the user can still continue with the flow in some way
    func collectPayment(using: CardReaderDiscoveryMethod,
                        onFailure: @escaping (Error) -> Void,
                        onCancel: @escaping () -> Void,
                        onPaymentCompletion: @escaping () -> Void,
                        onCompleted: @escaping () -> Void)
}

/// Use case to collect payments from an order.
/// Orchestrates reader connection, payment, UI alerts, receipt handling and analytics.
///
final class CollectOrderPaymentUseCase: NSObject, CollectOrderPaymentProtocol {
    /// Currency Formatter
    ///
    private let currencyFormatter = CurrencyFormatter(currencySettings: ServiceLocator.currencySettings)

    /// Store's ID.
    ///
    private let siteID: Int64

    /// Order to collect.
    ///
    private var order: Order

    /// Order total in decimal number. It is lazy so we avoid multiple conversions.
    /// It can be lazy because the order is a constant and never changes (this class is intended to be
    /// fired and disposed, not reused for multiple payment flows).
    ///
    private lazy var orderTotal: NSDecimalNumber? = {
        currencyFormatter.convertToDecimal(order.total)
    }()

    /// Formatted amount to collect.
    ///
    private let formattedAmount: String

    private let stores: StoresManager

    private let analyticsTracker: CollectOrderPaymentAnalyticsTracking

    /// View Controller used to present alerts.
    ///
    private let rootViewController: UIViewController

    /// Alerts presenter: alerts from the various parts of the payment process are forwarded here
    ///
    private let alertsPresenter: CardPresentPaymentAlertsPresenting

    /// Onboarding presenter: shows steps for payment setup when required
    ///
    private let onboardingPresenter: CardPresentPaymentsOnboardingPresenting

    /// Stores the card reader listener subscription while trying to connect to one.
    ///
    private var readerSubscription: AnyCancellable?

    private let configuration: CardPresentPaymentsConfiguration

    private let paymentOrchestrator: PaymentCaptureOrchestrating

    /// Coordinates emailing a receipt after payment success.
    private var receiptEmailCoordinator: CardPresentPaymentReceiptEmailCoordinator?

    private let preflightController: CardPresentPaymentPreflightControllerProtocol

    private var cancellables: Set<AnyCancellable> = []

    init(siteID: Int64,
         order: Order,
         formattedAmount: String,
         rootViewController: UIViewController,
         onboardingPresenter: CardPresentPaymentsOnboardingPresenting,
         configuration: CardPresentPaymentsConfiguration,
         stores: StoresManager = ServiceLocator.stores,
         paymentOrchestrator: PaymentCaptureOrchestrating = PaymentCaptureOrchestrator(),
         orderDurationRecorder: OrderDurationRecorderProtocol = OrderDurationRecorder.shared,
         alertsPresenter: CardPresentPaymentAlertsPresenting? = nil,
         preflightController: CardPresentPaymentPreflightControllerProtocol? = nil,
         analyticsTracker: CollectOrderPaymentAnalyticsTracking? = nil) {
        self.siteID = siteID
        self.order = order
        self.formattedAmount = formattedAmount
        self.rootViewController = rootViewController
        self.onboardingPresenter = onboardingPresenter
        self.alertsPresenter = alertsPresenter ?? CardPresentPaymentAlertsPresenter(rootViewController: rootViewController)
        self.configuration = configuration
        self.stores = stores
        self.paymentOrchestrator = paymentOrchestrator
        self.preflightController = preflightController ?? CardPresentPaymentPreflightController(siteID: siteID,
                                                                                                configuration: configuration,
                                                                                                rootViewController: rootViewController,
                                                                                                alertsPresenter: self.alertsPresenter,
                                                                                                onboardingPresenter: onboardingPresenter)
        self.analyticsTracker = analyticsTracker ?? CollectOrderPaymentAnalytics(siteID: siteID,
                                                                                 analytics: ServiceLocator.analytics,
                                                                                 configuration: configuration,
                                                                                 orderDurationRecorder: orderDurationRecorder)
    }

    /// Starts the collect payment flow.
    /// 1. Checks valid total
    /// 2. Calls CardReaderPreflightController to get a connected reader
    /// 3. Hands off to PaymentCaptureOrchestrator to perform the payment
    /// 4. Shows payment messages using an alert provider appropriate to the reader type
    /// 5. Handles receipt alerts on success
    /// 6. Allows retry on failure
    /// 7. Tracks payment analytics
    ///
    ///
    /// - Parameter onFailure: Closure invoked after the payment process fails.
    /// - Parameter onCancel: Closure invoked after the flow is cancelled
    /// - Parameter onCompleted: Closure invoked after the flow has been totally completed, currently after merchant has handled the receipt.
    func collectPayment(using discoveryMethod: CardReaderDiscoveryMethod,
                        onFailure: @escaping (Error) -> Void,
                        onCancel: @escaping () -> Void,
                        onPaymentCompletion: @escaping () -> Void,
                        onCompleted: @escaping () -> Void) {
        preflightController.readerConnection.sink { [weak self] connectionResult in
            guard let self = self else { return }
            self.analyticsTracker.preflightResultReceived(connectionResult)
            switch connectionResult {
            case .completed(let reader, let paymentGatewayAccount):
                let paymentAlertProvider = reader.paymentAlertProvider()
                self.attemptPayment(alertProvider: paymentAlertProvider,
                                    paymentGatewayAccount: paymentGatewayAccount,
                                    onCompletion: { [weak self] result in
                    guard let self = self else { return }
                    // Inform about the collect payment state
                    switch result {
                    case .failure(CollectOrderPaymentUseCaseError.flowCanceledByUser):
                        self.rootViewController.presentedViewController?.dismiss(animated: true)
                        return onCancel()
                    case .failure(let error):
                        CardPresentPaymentOnboardingStateCache.shared.invalidate()
                        return onFailure(error)
                    case .success(let paymentData):
                        // Handle payment receipt
                        self.storeInPersonPaymentsTransactionDateIfFirst(using: reader.readerType)
                        self.presentReceiptAlert(receiptParameters: paymentData.receiptParameters,
                                                 alertProvider: paymentAlertProvider,
                                                 onCompleted: onCompleted)
                    }
                    onPaymentCompletion()
                })
            case .canceled(let cancellationSource, _):
                self.handlePaymentCancellation(from: cancellationSource)
                onCancel()
            case .none:
                break
            }
        }
        .store(in: &cancellables)

        Task {
            await preflightController.start(discoveryMethod: discoveryMethod)
        }
    }
}

private extension CardReader {
    func paymentAlertProvider() -> CardReaderTransactionAlertsProviding {
        switch readerType {
        case .appleBuiltIn:
            return BuiltInCardReaderPaymentAlertsProvider()
        default:
            return BluetoothCardReaderPaymentAlertsProvider(transactionType: .collectPayment)
        }
    }
}

// MARK: Private functions
private extension CollectOrderPaymentUseCase {
    /// Checks whether the amount to be collected is valid: (not nil, convertible to decimal, higher than minimum amount ...)
    ///
    func isTotalAmountValid() -> Bool {
        guard let orderTotal = orderTotal else {
            return false
        }

        /// Bail out if the order amount is below the minimum allowed:
        /// https://stripe.com/docs/currencies#minimum-and-maximum-charge-amounts
        return orderTotal as Decimal >= configuration.minimumAllowedChargeAmount as Decimal
    }

    /// Determines and returns the error that provoked the amount being invalid
    ///
    func totalAmountInvalidError() -> Error {
        let orderTotalAmountCanBeConverted = orderTotal != nil

        guard orderTotalAmountCanBeConverted,
              let minimum = currencyFormatter.formatAmount(configuration.minimumAllowedChargeAmount, with: order.currency) else {
            return NotValidAmountError.other
        }

        return NotValidAmountError.belowMinimumAmount(amount: minimum)
    }

    func handleTotalAmountInvalidError(_ error: Error,
                                       onCompleted: @escaping () -> ()) {
        analyticsTracker.trackPaymentFailure(with: error)
        DDLogError("💳 Error: failed to capture payment for order. Order amount is below minimum or not valid")
        alertsPresenter.present(viewModel: CardPresentModalNonRetryableError(amount: formattedAmount,
                                                                             error: totalAmountInvalidError(),
                                                                             onDismiss: onCompleted))
    }

    func isOrderAwaitingPayment() -> Bool {
        order.datePaid == nil
    }

    func checkOrderIsStillEligibleForPayment(alertProvider paymentAlerts: CardReaderTransactionAlertsProviding,
                                             onPaymentCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> (),
                                             onCheckCompletion: @escaping (Result<Void, Error>) -> Void) {
        guard ServiceLocator.featureFlagService.isFeatureFlagEnabled(.refreshOrderBeforeInPersonPayment) else {
            return onCheckCompletion(.success(()))
        }

        alertsPresenter.present(viewModel: paymentAlerts.validatingOrder(onCancel: { [weak self] in
            self?.cancelPayment(from: .paymentValidatingOrder) {
                onPaymentCompletion(.failure(CollectOrderPaymentUseCaseError.flowCanceledByUser))
            }
        }))

        let action = OrderAction.retrieveOrder(siteID: order.siteID, orderID: order.orderID) { [weak self] (order, error) in
            guard let self = self else { return }
            guard let order = order else {
                DDLogError("⛔️ Error synchronizing Order: \(error.debugDescription)")
                if let error = error {
                    return onCheckCompletion(.failure(CollectOrderPaymentUseCaseError.couldNotRefreshOrder(error)))
                } else {
                    return onCheckCompletion(.failure(CollectOrderPaymentUseCaseError.unknownErrorRefreshingOrder))
                }
            }

            self.order = order

            guard self.isTotalAmountValid() else {
                return onCheckCompletion(.failure(self.totalAmountInvalidError()))
            }

            guard self.isOrderAwaitingPayment() else {
                return onCheckCompletion(.failure(CollectOrderPaymentUseCaseError.orderAlreadyPaid))
            }

            onCheckCompletion(.success(()))
        }

        stores.dispatch(action)
    }

    /// Attempts to collect payment for an order.
    ///
    func attemptPayment(alertProvider paymentAlerts: CardReaderTransactionAlertsProviding,
                        paymentGatewayAccount: PaymentGatewayAccount,
                        onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        checkOrderIsStillEligibleForPayment(alertProvider: paymentAlerts, onPaymentCompletion: onCompletion) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                return self.handlePaymentFailureAndRetryPayment(error,
                                                               alertProvider: paymentAlerts,
                                                               paymentGatewayAccount: paymentGatewayAccount,
                                                               onCompletion: onCompletion)
            case .success:
                guard let orderTotal = self.orderTotal else {
                    onCompletion(.failure(NotValidAmountError.other))
                    return
                }

                // Start collect payment process
                self.paymentOrchestrator.collectPayment(
                    for: self.order,
                    orderTotal: orderTotal,
                    paymentGatewayAccount: paymentGatewayAccount,
                    paymentMethodTypes: self.configuration.paymentMethods.map(\.rawValue),
                    stripeSmallestCurrencyUnitMultiplier: self.configuration.stripeSmallestCurrencyUnitMultiplier,
                    onPreparingReader: { [weak self] in
                        self?.alertsPresenter.present(viewModel: paymentAlerts.preparingReader(onCancel: {
                            self?.cancelPayment(from: .paymentPreparingReader) {
                                onCompletion(.failure(CollectOrderPaymentUseCaseError.flowCanceledByUser))
                            }
                        }))
                    },
                    onWaitingForInput: { [weak self] inputMethods in
                        guard let self = self else { return }
                        self.alertsPresenter.present(
                            viewModel: paymentAlerts.tapOrInsertCard(
                                title: Localization.collectPaymentTitle(username: self.order.billingAddress?.firstName),
                                amount: self.formattedAmount,
                                inputMethods: inputMethods,
                                onCancel: { [weak self] in
                                    self?.cancelPayment(from: .paymentWaitingForInput) {
                                        onCompletion(.failure(CollectOrderPaymentUseCaseError.flowCanceledByUser))
                                    }
                                })
                        )
                    }, onProcessingMessage: { [weak self] in
                        guard let self = self else { return }
                        // Waiting message
                        self.alertsPresenter.present(
                            viewModel: paymentAlerts.processingTransaction(
                                title: Localization.processingPaymentTitle(username: self.order.billingAddress?.firstName)))
                    }, onDisplayMessage: { [weak self] message in
                        guard let self = self else { return }
                        // Reader messages. EG: Remove Card
                        self.alertsPresenter.present(viewModel: paymentAlerts.displayReaderMessage(message: message))
                    }, onProcessingCompletion: { [weak self] intent in
                        self?.analyticsTracker.trackProcessingCompletion(intent: intent)
                        self?.markOrderAsPaidIfNeeded(intent: intent)
                    }, onCompletion: { [weak self] result in
                        switch result {
                        case .success(let capturedPaymentData):
                            self?.handleSuccessfulPayment(capturedPaymentData: capturedPaymentData)
                            onCompletion(.success(capturedPaymentData))
                        case .failure(CardReaderServiceError.paymentMethodCollection(.commandCancelled(let cancellationSource))):
                            switch cancellationSource {
                            case .reader:
                                self?.handlePaymentCancellationFromReader(alertProvider: paymentAlerts)
                            default:
                                self?.handlePaymentCancellation(from: .other)
                            }
                        case .failure(let error):
                            self?.handlePaymentFailureAndRetryPayment(error,
                                                                      alertProvider: paymentAlerts,
                                                                      paymentGatewayAccount: paymentGatewayAccount,
                                                                      onCompletion: onCompletion)
                        }
                    })
            }
        }
    }

    /// Tracks the successful payments
    ///
    func handleSuccessfulPayment(capturedPaymentData: CardPresentCapturedPaymentData) {
        analyticsTracker.trackSuccessfulPayment(capturedPaymentData: capturedPaymentData)
    }

    func handlePaymentCancellation(from cancellationSource: WooAnalyticsEvent.InPersonPayments.CancellationSource) {
        analyticsTracker.trackPaymentCancelation(cancelationSource: cancellationSource)
        alertsPresenter.dismiss()
    }

    func handlePaymentCancellationFromReader(alertProvider paymentAlerts: CardReaderTransactionAlertsProviding) {
        analyticsTracker.trackPaymentCancelation(cancelationSource: .reader)
        guard let dismissedOnReaderAlert = paymentAlerts.cancelledOnReader() else {
            return alertsPresenter.dismiss()
        }
        alertsPresenter.present(viewModel: dismissedOnReaderAlert)
    }

    /// Log the failure reason, cancel the current payment and retry it if possible.
    ///
    func handlePaymentFailureAndRetryPayment(_ error: Error,
                                             alertProvider paymentAlerts: CardReaderTransactionAlertsProviding,
                                             paymentGatewayAccount: PaymentGatewayAccount,
                                             onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        guard ServiceLocator.featureFlagService.isFeatureFlagEnabled(.reusePaymentIntentOnRetryInPersonPayment) else {
            return legacyHandlePaymentFailureAndRetryPayment(error,
                                                             alertProvider: paymentAlerts,
                                                             paymentGatewayAccount: paymentGatewayAccount,
                                                             onCompletion: onCompletion)
        }

        DDLogError("Failed to collect payment: \(error.localizedDescription)")

        analyticsTracker.trackPaymentFailure(with: error)

        guard let retryableError = error as? CardPaymentErrorProtocol else {
            return presentNonRetryableError(error: error,
                                            paymentAlerts: paymentAlerts,
                                            onCompletion: onCompletion)
        }
        switch retryableError.retryApproach {
        case .restart:
            presentRetryByRestartingError(error: error,
                                          paymentAlerts: paymentAlerts,
                                          paymentGatewayAccount: paymentGatewayAccount,
                                          onCompletion: onCompletion)
        case .reuseIntent:
            presentRetryWithoutRestartingError(error: error,
                                               paymentAlerts: paymentAlerts,
                                               paymentGatewayAccount: paymentGatewayAccount,
                                               onCompletion: onCompletion)
        case .dontRetry:
            presentNonRetryableError(error: error,
                                     paymentAlerts: paymentAlerts,
                                     onCompletion: onCompletion)
        }
    }

    private func presentRetryByRestartingError(error: Error,
                                               paymentAlerts: CardReaderTransactionAlertsProviding,
                                               paymentGatewayAccount: PaymentGatewayAccount,
                                               onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        alertsPresenter.present(
            viewModel: paymentAlerts.error(error: error,
                                           tryAgain: { [weak self] in
                                               // Cancel current payment
                                               self?.paymentOrchestrator.cancelPayment() { [weak self] result in
                                                   guard let self = self else { return }

                                                   switch result {
                                                   case .success, .failure(CardReaderServiceError.paymentCancellation(.noActivePaymentIntent)):
                                                       // Retry payment
                                                       self.attemptPayment(alertProvider: paymentAlerts,
                                                                           paymentGatewayAccount: paymentGatewayAccount,
                                                                           onCompletion: onCompletion)
                                                   case .failure(let cancelError):
                                                       // Inform that payment can't be retried.
                                                       self.alertsPresenter.present(
                                                        viewModel: paymentAlerts.nonRetryableError(error: cancelError) {
                                                            onCompletion(.failure(error))
                                                        })
                                                   }
                                               }
                                           }, dismissCompletion: {
                                               onCompletion(.failure(error))
                                           })
        )
    }

    private func presentRetryWithoutRestartingError(error: Error,
                                                    paymentAlerts: CardReaderTransactionAlertsProviding,
                                                    paymentGatewayAccount: PaymentGatewayAccount,
                                                    onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        alertsPresenter.present(
            viewModel: paymentAlerts.error(
                error: error,
                tryAgain: { [weak self] in
                    guard let self = self else { return }
                    self.checkOrderIsStillEligibleForPayment(alertProvider: paymentAlerts, onPaymentCompletion: onCompletion) { result in
                        switch result {
                        case .failure(let error):
                            return self.handlePaymentFailureAndRetryPayment(error,
                                                                            alertProvider: paymentAlerts,
                                                                            paymentGatewayAccount: paymentGatewayAccount,
                                                                            onCompletion: onCompletion)
                        case .success:
                            self.paymentOrchestrator.retryPayment(for: self.order) { [weak self] result in
                                guard let self = self else { return }
                                switch result {
                                case .success(let capturedPaymentData):
                                    self.handleSuccessfulPayment(capturedPaymentData: capturedPaymentData)
                                    onCompletion(.success(capturedPaymentData))
                                case .failure(CardReaderServiceError.paymentMethodCollection(.commandCancelled(let cancellationSource))):
                                    switch cancellationSource {
                                    case .reader:
                                        self.handlePaymentCancellationFromReader(alertProvider: paymentAlerts)
                                    default:
                                        self.handlePaymentCancellation(from: .other)
                                    }
                                case .failure(let error):
                                    let retryError = CollectOrderPaymentUseCaseError.alreadyRetried(error)
                                    self.handlePaymentFailureAndRetryPayment(retryError,
                                                                             alertProvider: paymentAlerts,
                                                                             paymentGatewayAccount: paymentGatewayAccount,
                                                                             onCompletion: onCompletion)
                                }
                            }
                        }
                    }
                }, dismissCompletion: {
                    onCompletion(.failure(error))
                })
        )
    }

    private func presentNonRetryableError(error: Error,
                                          paymentAlerts: CardReaderTransactionAlertsProviding,
                                          onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        alertsPresenter.present(
            viewModel: paymentAlerts.nonRetryableError(error: error,
                                                       dismissCompletion: {
                                                           onCompletion(.failure(error))
                                                       }))
    }

    /// Cancels payment and record analytics.
    ///
    func cancelPayment(from cancelationSource: WooAnalyticsEvent.InPersonPayments.CancellationSource,
                       onCompleted: @escaping () -> ()) {
        paymentOrchestrator.cancelPayment { [weak self] _ in
            self?.analyticsTracker.trackPaymentCancelation(cancelationSource: cancelationSource)
            onCompleted()
        }
    }

    /// Allow merchants to print or email the payment receipt.
    ///
    func presentReceiptAlert(receiptParameters: CardPresentReceiptParameters,
                             alertProvider paymentAlerts: CardReaderTransactionAlertsProviding,
                             onCompleted: @escaping () -> ()) {
        // Present receipt alert
        alertsPresenter.present(viewModel: paymentAlerts.success(printReceipt: { [order, configuration, weak self] in
            guard let self = self else { return }

            // Delegate print action
            Task { @MainActor in
                await ReceiptActionCoordinator.printReceipt(for: order,
                                                            params: receiptParameters,
                                                            countryCode: configuration.countryCode,
                                                            cardReaderModel: self.analyticsTracker.connectedReaderModel,
                                                            stores: self.stores)

                // Inform about flow completion.
                onCompleted()
            }
        }, emailReceipt: { [order, analyticsTracker, paymentOrchestrator, weak self] in
            guard let self = self else { return }

            analyticsTracker.trackEmailTapped()

            // Request & present email
            paymentOrchestrator.emailReceipt(for: order, params: receiptParameters) { [weak self] emailContent in
                self?.presentEmailForm(content: emailContent, onCompleted: onCompleted)
            }
        }, noReceiptAction: {
            // Inform about flow completion.
            onCompleted()
        }))
    }

    /// Presents the native email client with the provided content.
    ///
    func presentEmailForm(content: String, onCompleted: @escaping () -> ()) {
        let coordinator = CardPresentPaymentReceiptEmailCoordinator(countryCode: configuration.countryCode,
                                                                    cardReaderModel: analyticsTracker.connectedReaderModel)
        receiptEmailCoordinator = coordinator
        coordinator.presentEmailForm(data: .init(content: content,
                                                 order: order,
                                                 storeName: stores.sessionManager.defaultSite?.name),
                                     from: rootViewController,
                                     completion: onCompleted)
    }

    func storeInPersonPaymentsTransactionDateIfFirst(using cardReaderType: CardReaderType) {
        stores.dispatch(AppSettingsAction.storeInPersonPaymentsTransactionIfFirst(siteID: order.siteID,
                                                                                  cardReaderType: cardReaderType))
    }
}

// MARK: Legacy retry payment handling
// Remove when reusePaymentIntentOnRetryInPersonPayment feature flag is removed
private extension CollectOrderPaymentUseCase {
    func legacyHandlePaymentFailureAndRetryPayment(_ error: Error,
                                                   alertProvider paymentAlerts: CardReaderTransactionAlertsProviding,
                                                   paymentGatewayAccount: PaymentGatewayAccount,
                                                   onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        DDLogError("Failed to collect payment: \(error.localizedDescription)")

        analyticsTracker.trackPaymentFailure(with: error)

        if canRetryPayment(with: error) {
            presentRetryByRestartingError(error: error,
                                          paymentAlerts: paymentAlerts,
                                          paymentGatewayAccount: paymentGatewayAccount,
                                          onCompletion: onCompletion)
        } else {
            presentNonRetryableError(error: error,
                                     paymentAlerts: paymentAlerts,
                                     onCompletion: onCompletion)
        }
    }

    private func canRetryPayment(with error: Error) -> Bool {
        switch error {
        case let serviceError as CardReaderServiceError:
            switch serviceError {
            case .paymentMethodCollection(let underlyingError),
                    .paymentCapture(let underlyingError),
                    .paymentCancellation(let underlyingError):
                return canRetryPayment(underlyingError: underlyingError)
            default:
                return true
            }
        case let useCaseError as CollectOrderPaymentUseCaseError:
            switch useCaseError {
            case .flowCanceledByUser, .orderAlreadyPaid, .alreadyRetried:
                return false
            case .paymentGatewayNotFound, .unknownErrorRefreshingOrder, .couldNotRefreshOrder:
                return true
            }
        default:
            return true
        }
    }

    private func canRetryPayment(underlyingError: UnderlyingError) -> Bool {
        switch underlyingError {
        case .notConnectedToReader,
                .commandNotAllowedDuringCall,
                .featureNotAvailableWithConnectedReader:
            return false
        default:
            return true
        }
    }

    private func presentRetryableError(error: Error,
                                           paymentAlerts: CardReaderTransactionAlertsProviding,
                                           paymentGatewayAccount: PaymentGatewayAccount,
                                       onCompletion: @escaping (Result<CardPresentCapturedPaymentData, Error>) -> ()) {
        alertsPresenter.present(
            viewModel: paymentAlerts.error(error: error,
                                           tryAgain: { [weak self] in
                                               // Cancel current payment
                                               self?.paymentOrchestrator.cancelPayment() { [weak self] result in
                                                   guard let self = self else { return }

                                                   switch result {
                                                   case .success:
                                                       // Retry payment
                                                       self.attemptPayment(alertProvider: paymentAlerts,
                                                                           paymentGatewayAccount: paymentGatewayAccount,
                                                                           onCompletion: onCompletion)
                                                   case .failure(let cancelError):
                                                       // Inform that payment can't be retried.
                                                       self.alertsPresenter.present(
                                                        viewModel: paymentAlerts.nonRetryableError(error: cancelError) {
                                                            onCompletion(.failure(error))
                                                        })
                                                   }
                                               }
                                           }, dismissCompletion: {
                                               onCompletion(.failure(error))
                                           })
        )
    }
}

// MARK: Interac handling
private extension CollectOrderPaymentUseCase {
    /// For certain payment methods like Interac in Canada, the payment is captured on the client side (customer is charged).
    /// To prevent the order from multiple charges after the first client side success, the order is marked as paid locally in case of any
    /// potential failures until the next order refresh.
    func markOrderAsPaidIfNeeded(intent: PaymentIntent) {
        guard let paymentMethod = intent.paymentMethod() else {
            return
        }
        switch paymentMethod {
        case .interacPresent:
            let action = OrderAction.markOrderAsPaidLocally(siteID: order.siteID, orderID: order.orderID, datePaid: Date()) { _ in }
            stores.dispatch(action)
        default:
            return
        }
    }
}

// MARK: Definitions
private extension CollectOrderPaymentUseCase {
    /// Mailing a receipt failed but the SDK didn't return a more specific error
    ///
    struct UnknownEmailError: Error {}


    enum Localization {
        private static let emailSubjectWithStoreName = NSLocalizedString("Your receipt from %1$@",
                                                                 comment: "Subject of email sent with a card present payment receipt")
        private static let emailSubjectWithoutStoreName = NSLocalizedString("Your receipt",
                                                                    comment: "Subject of email sent with a card present payment receipt")
        static func emailSubject(storeName: String?) -> String {
            guard let storeName = storeName, storeName.isNotEmpty else {
                return emailSubjectWithoutStoreName
            }
            return .localizedStringWithFormat(emailSubjectWithStoreName, storeName)
        }

        private static let collectPaymentWithoutName = NSLocalizedString("Collect payment",
                                                                 comment: "Alert title when starting the collect payment flow without a user name.")
        private static let collectPaymentWithName = NSLocalizedString("Collect payment from %1$@",
                                                                 comment: "Alert title when starting the collect payment flow with a user name.")
        static func collectPaymentTitle(username: String?) -> String {
            guard let username = username, username.isNotEmpty else {
                return collectPaymentWithoutName
            }
            return .localizedStringWithFormat(collectPaymentWithName, username)
        }

        private static let processingPaymentWithoutName = NSLocalizedString(
            "Processing payment",
            comment: "Alert title when processing a payment without a user name.")
        private static let processingPaymentWithName = NSLocalizedString(
            "Processing payment from %1$@",
            comment: "Alert title when processing a payment with a user name.")
        static func processingPaymentTitle(username: String?) -> String {
            guard let username = username, username.isNotEmpty else {
                return processingPaymentWithoutName
            }
            return .localizedStringWithFormat(processingPaymentWithName, username)
        }
    }
}

extension CollectOrderPaymentUseCase {
    enum NotValidAmountError: Error, LocalizedError, Equatable {
        case belowMinimumAmount(amount: String)
        case other

        var errorDescription: String? {
            switch self {
            case .belowMinimumAmount(let amount):
                return String.localizedStringWithFormat(Localization.belowMinimumAmount, amount)
            case .other:
                return Localization.defaultMessage
            }
        }

        private enum Localization {
            static let defaultMessage = NSLocalizedString(
                "Unable to process payment. Order total amount is not valid.",
                comment: "Error message when the order amount is not valid."
            )

            static let belowMinimumAmount = NSLocalizedString(
                "Unable to process payment. Order total amount is below the minimum amount you can charge, which is %1$@",
                comment: "Error message when the order amount is below the minimum amount allowed."
            )
        }
    }

    enum CollectOrderPaymentUseCaseError: LocalizedError {
        case flowCanceledByUser
        case paymentGatewayNotFound
        case unknownErrorRefreshingOrder
        case couldNotRefreshOrder(Error)
        case orderAlreadyPaid
        case alreadyRetried(Error)

        var errorDescription: String? {
            switch self {
            case .flowCanceledByUser:
                return Localization.paymentCancelledLocalizedDescription
            case .paymentGatewayNotFound:
                return Localization.paymentGatewayNotFoundLocalizedDescription
            case .unknownErrorRefreshingOrder:
                return Localization.unknownErrorWhileRefreshingOrderLocalizedDescription
            case .couldNotRefreshOrder(let error as LocalizedError):
                return error.errorDescription
            case .couldNotRefreshOrder(let error):
                return String.localizedStringWithFormat(Localization.couldNotRefreshOrderLocalizedDescription, error.localizedDescription)
            case .orderAlreadyPaid:
                return Localization.orderAlreadyPaidLocalizedDescription
            case .alreadyRetried(let error as LocalizedError):
                return error.errorDescription
            case .alreadyRetried(let error):
                return String.localizedStringWithFormat(Localization.couldNotRetryPaymentLocalizedDescription, error.localizedDescription)
            }
        }

        private enum Localization {
            static let couldNotRefreshOrderLocalizedDescription = NSLocalizedString(
                "Unable to process payment. We could not fetch the latest order details. Please check your network " +
                "connection and try again. Underlying error: %1$@",
                comment: "Error message when collecting an In-Person Payment and unable to update the order. %!$@ will " +
                "be replaced with further error details.")

            static let unknownErrorWhileRefreshingOrderLocalizedDescription = NSLocalizedString(
                "Unable to process payment. We could not fetch the latest order details. Please check your network " +
                "connection and try again.",
                comment: "Error message when collecting an In-Person Payment and unable to update the order.")

            static let orderAlreadyPaidLocalizedDescription = NSLocalizedString(
                "Unable to process payment. This order is already paid, taking a further payment would result in the " +
                "customer being charged twice for their order.",
                comment: "Error message shown during In-Person Payments when the order is found to be paid after it's refreshed.")

            static let paymentGatewayNotFoundLocalizedDescription = NSLocalizedString(
                "Unable to process payment. We could not connect to the payment system. Please contact support if this " +
                "error continues.",
                comment: "Error message shown during In-Person Payments when the payment gateway is not available.")

            static let paymentCancelledLocalizedDescription = NSLocalizedString(
                "The payment was cancelled.", comment: "Message shown if a payment cancellation is shown as an error.")

            static let couldNotRetryPaymentLocalizedDescription = NSLocalizedString(
                "Unable to process payment. We could not complete this payment while retrying. Underlying error: %1$@",
                comment: "Error message when retrying an In-Person Payment and an unknown error is received.")
        }
    }
}

enum CardPaymentRetryApproach {
    case reuseIntent
    case restart
    case dontRetry
}

protocol CardPaymentErrorProtocol {
    var retryApproach: CardPaymentRetryApproach { get }
}

extension CardReaderServiceError: CardPaymentErrorProtocol {
    var retryApproach: CardPaymentRetryApproach {
        switch self {
        case .paymentMethodCollection(let underlyingError), .paymentCapture(let underlyingError), .paymentCaptureWithPaymentMethod(let underlyingError, _):
            guard canRetryPayment(underlyingError: underlyingError) else {
                return .dontRetry
            }
            return .reuseIntent
        case .retryNotPossibleUnknownCause,
                .retryNotPossibleNoActivePayment,
                .retryNotPossibleProcessingInProgress,
                .retryNotPossibleActivePaymentCancelled,
                .retryNotPossibleActivePaymentSucceeded,
                .paymentCancellation:
            return .dontRetry
        default:
            return .restart
        }
    }

    private func canRetryPayment(underlyingError: UnderlyingError) -> Bool {
        switch underlyingError {
        case .notConnectedToReader,
                .commandNotAllowedDuringCall,
                .featureNotAvailableWithConnectedReader:
            return false
        default:
            return true
        }
    }
}

extension CollectOrderPaymentUseCase.CollectOrderPaymentUseCaseError: CardPaymentErrorProtocol {
    var retryApproach: CardPaymentRetryApproach {
        switch self {
        case .flowCanceledByUser, .orderAlreadyPaid, .alreadyRetried:
            return .dontRetry
        case .paymentGatewayNotFound:
            return .restart
        case .unknownErrorRefreshingOrder, .couldNotRefreshOrder:
            return .reuseIntent
        }
    }
}
