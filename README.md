<img src="iap_engine.svg" alt="IAP Entitlement Engine" width="200" />

# In-App Purchase Entitlement Swift Package

![Swift Package](https://img.shields.io/badge/Swift-6.4-orange.svg)

## Overview

A server-side Swift package that turns verified App Store and Google Play subscription data into an up-to-date `Order` and a push notification. Both stores run through the same entitlement rules.

The engine trusts its inputs. It does not fetch or verify purchases, so verify them with Apple or Google first.

## Features

- Auto-renewable subscriptions on the App Store and Google Play
- Weekly, monthly and yearly products
- Trials, introductory offers, grace periods, account hold, pause, refunds and upgrades
- Push notifications through APNs and Firebase Cloud Messaging (FCM)
- Customizable notification copy through `EntitlementMessages`

## Requirements

- Swift 6.4 or later
- macOS 15 or iOS 18 and later, or Linux

## Installation

```swift
.package(url: "https://github.com/needle-tail/iap-entitlement-engine.git", from: "1.0.0")
```

## Usage

Implement `EntitlementStoreDelegate` to save orders, then create an engine. Engines are cheap and hold no per-call state, so one instance can process many subscriptions at once.

### App Store

```swift
let engine = EntitlementEngine(
    storeDelegate: store,
    weeklyProductID: "com.example.weekly",
    monthlyProductID: "com.example.monthly",
    yearlyProductID: "com.example.yearly",
    apnTopic: "com.example.app",
    deviceToken: deviceToken
)

try await engine.processReceipt(
    apns: apnsClient,
    order: order,
    orderId: order.id.uuidString,
    latestReceiptInfo: latestReceiptInfo,
    pendingRenewalInfo: pendingRenewalInfo
)
```

`latestReceiptInfo` and `pendingRenewalInfo` use the `verifyReceipt` format, which Apple has deprecated. Pass the most recent transaction for the subscription.

### Google Play

Call `purchases.subscriptionsv2.get` when you receive a real-time developer notification, and pass its response to the engine. If Play sells one product with several base plans, use the base plan IDs as the product IDs.

```swift
let engine = EntitlementEngine(
    storeDelegate: store,
    weeklyProductID: "weekly",
    monthlyProductID: "monthly",
    yearlyProductID: "yearly"
)

let notifier = FCMEntitlementNotifier(
    projectID: "my-firebase-project",
    registrationToken: registrationToken,
    accessTokenProvider: tokenProvider
)

let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: response)

try await engine.processGooglePlayPurchase(
    notifier: notifier,
    order: order,
    orderId: order.id.uuidString,
    purchase: purchase,
    isRevoked: notificationType == subscriptionRevoked
)
```

Your server has to handle these parts itself:

- **Access tokens:** implement `FCMAccessTokenProvider` with your service account, and cache tokens there.
- **Revocations:** pass `isRevoked: true` for `SUBSCRIPTION_REVOKED`. Google reports revocations as a plain expiry, so the purchase alone cannot show one.
- **Acknowledgement:** check `purchase.needsAcknowledgement` and acknowledge new purchases. Google refunds purchases that are not acknowledged within three days.
- **Replaced subscriptions:** after an upgrade or downgrade, map the order to the new purchase token. The old token leaves the order unchanged.
- **Test purchases:** `purchase.isTestPurchase` is exposed so you can decide how to treat them.

## Behavior

| Situation | Access | Push |
| --- | --- | --- |
| Active or renewed | Yes | Only for a new subscriber or a product change |
| Trial or intro offer | Yes | When it starts |
| Auto-renew off, under 24 hours left | Yes | Expiry warning |
| Grace period | Yes | Payment issue |
| Google account hold | No | Payment issue |
| Google pause | No | None |
| Expired | No | None |
| Refunded or revoked | No | Cancelled |
| Upgraded (Apple) | Unchanged | Thank you |
| Pending or replaced (Google) | Unchanged | None |
| Unknown product | No | Not subscribed, if they were subscribed |

The order is saved before the push is sent. If saving fails, no push is sent. If the push fails, the error is thrown and the saved entitlement stands. Retrying is safe, but one-off messages are not resent because the order has already changed.

Grace period and expiry warnings repeat each time you process that state. They use a collapse ID, so a new copy replaces the old one on the device, but you should still process on store events rather than on a short timer.

Malformed or unknown store data throws an `EntitlementError`, and nothing is saved or sent. FCM throws `FCMError.unregistered` when a token goes stale, so you can stop using it.

## Upgrading

- `processReceipt` now throws on failures that it used to log and report as `.ok`.
- `processReceipt` accepts any `APNSClientProtocol`, and requires `apnTopic` and `deviceToken`.
- The default notification copy changed. Use `EntitlementMessages` to set your own.
- `currentDate` now returns the current time rather than the time the engine was created.

## Contributing

Contributions are welcome! If you have suggestions for improvements or find bugs, please open an issue or submit a pull request.

## License

This package is licensed under the MIT License. See the [LICENSE](./LICENSE.md) file for more information.

## Contact

For any inquiries or support, please contact [support@needletails.com](mailto:support@needletails.com).
