<img src="iap_engine.svg" alt="IAP Entitlement Engine" width="200" />

# In-App Purchase Entitlement Swift Package

![Swift Package](https://img.shields.io/badge/Swift-6.4-orange.svg)

## Overview

A server-side Swift package that turns verified App Store and Google Play subscription data into an up-to-date `Order` and a push notification. Both stores run through the same entitlement rules.

The engine trusts its inputs. It does not fetch or verify purchases, so verify them with Apple or Google first.

## Features

- Auto-renewable subscriptions on the App Store and Google Play
- Weekly, monthly and yearly plans
- Trials, introductory offers, grace periods, account hold, pause, refunds and upgrades
- Push notifications through APNs and Firebase Cloud Messaging (FCM)
- Customizable notification copy through `EntitlementMessages`

## Requirements

- Swift 6.4 or later
- macOS 15 or iOS 18 and later, or Linux

Two limits come from the HTTP/3 packages under HTTPConnectionKit, which are still below 1.0:

- Your package graph is held at `swift-collections` 1.6.0 and `swift-nio-http3` 0.3.x.
- Thread Sanitizer builds fail on Swift 6.4, because the compiler crashes in that `swift-collections` release. Address Sanitizer builds work.

## Installation

Add the package:

```swift
.package(url: "https://github.com/needletails/iap-entitlement-engine.git", from: "1.0.0")
```

Then add the product to your target:

```swift
.product(name: "IAPEntitlementEngine", package: "iap-entitlement-engine")
```

## Usage

Implement `EntitlementStoreDelegate` to save orders, then create an engine. Engines are cheap and hold no per-call state, so one instance can process many subscriptions at once.

```swift
import IAPEntitlementEngine

struct OrderStore: EntitlementStoreDelegate {
    func updateOrder(_ order: Order, replacing previous: Order) async throws {
        // Save `order`. Throw if what is stored no longer matches `previous`.
    }
}

let engine = EntitlementEngine(
    storeDelegate: OrderStore(),
    weeklyProductID: "com.example.weekly",
    monthlyProductID: "com.example.monthly",
    yearlyProductID: "com.example.yearly"
)
```

Pass an empty string for a plan you do not sell. If you have stopped selling a product that still has subscribers, list it in `retiredProductIDs`, as described under [Behavior](#behavior).

Every process call returns an `EntitlementResult`:

| Field | Meaning |
| --- | --- |
| `order` | The order as it now stands |
| `didSave` | Whether your delegate saved it |
| `accessExpiresAt` | When the access this call found ends, or `nil` if it found no end date |
| `notification` | The message that was due, if any |
| `pushFailure` | Why that message did not go out, or `nil` |

A call throws only when nothing was saved. Once the order is saved the call always returns, so answer your webhook with success and look at `pushFailure` separately.

Store `accessExpiresAt` when it has a value. When it is `nil`, look at `order`: if it is not subscribed, access has ended, so clear the date you stored. If it is still subscribed, the call concluded nothing, so keep the date you stored.

To find the order for an incoming event, give the store your order's ID when the purchase is made: as `appAccountToken` on the App Store, and as the obfuscated account ID on Google Play. Both come back in later events for a purchase made in your app. A purchase made outside it, such as a resubscribe in the Play Store, carries neither, so also keep the original transaction ID or the purchase token against the order. Read these from the store's payload, because the engine's types do not carry them.

### App Store

Use signed data from the App Store Server API or App Store Server Notifications V2 for new work. The `verifyReceipt` path below keeps working for apps that have not migrated.

#### Signed data

Verify the JWS strings first, then pass the decoded values to the engine. The engine does not check signatures.

Apple's [`app-store-server-library-swift`](https://github.com/apple/app-store-server-library-swift) caps `swift-crypto` below 4.0, and this package needs 5.0.3 or later, so the two cannot resolve together. Until Apple raises that cap, add our [fork](https://github.com/needletails/app-store-server-library-swift) to your server, which raises that limit:

```swift
.package(url: "https://github.com/needletails/app-store-server-library-swift.git", branch: "main")
```

Keep the product name `AppStoreServerLibrary`. A separate verifying service works too, or another JWS library, in which case you have to validate the certificate chain against Apple's root yourself.

Verify in your server target:

```swift
import AppStoreServerLibrary
import IAPEntitlementEngine

let verifier = try SignedDataVerifier(
    rootCertificates: appleRootCertificates,
    bundleId: "com.example.app",
    appAppleId: 1234567890,
    environment: .production,
    enableOnlineChecks: true
)

guard case .valid(let transaction) = await verifier.verifyAndDecodeTransaction(signedTransaction: signedTransactionInfo),
      case .valid(let renewal) = await verifier.verifyAndDecodeRenewalInfo(signedRenewalInfo: signedRenewalInfo)
else {
    return // Reject the data. Nothing has been changed.
}

let result = try await engine.processAppStoreTransaction(
    notifier: APNSEntitlementNotifier(client: apnsClient, topic: "com.example.app", deviceToken: deviceToken),
    order: order,
    transaction: AppStoreTransaction(
        productId: transaction.productId,
        originalTransactionId: transaction.originalTransactionId,
        expiresDate: transaction.expiresDate,
        isUpgraded: transaction.isUpgraded,
        revocationDate: transaction.revocationDate,
        revocationReason: transaction.rawRevocationReason,
        offerType: transaction.rawOfferType,
        offerDiscountType: transaction.rawOfferDiscountType
    ),
    renewalInfo: AppStoreRenewalInfo(
        originalTransactionId: renewal.originalTransactionId,
        autoRenewStatus: renewal.rawAutoRenewStatus,
        gracePeriodExpiresDate: renewal.gracePeriodExpiresDate,
        isInBillingRetryPeriod: renewal.isInBillingRetryPeriod,
        renewalDate: renewal.renewalDate
    )
)
```

If you verify with another JWS library, decode the verified payload JSON straight into `AppStoreTransaction` and `AppStoreRenewalInfo`. They read Apple's millisecond dates whatever date strategy the decoder uses.

Verification is left to your server because it needs your root certificates, bundle ID, app ID and environment.

Create `apnsClient` once and reuse it. It is built on HTTPConnectionKit, speaks HTTP/2 and signs its own provider tokens. The key type comes from `swift-crypto`, so add that package and `import Crypto`:

```swift
import Crypto

let apnsClient = HTTPConnectionAPNSClient(
    environment: .production,
    privateKey: try P256.Signing.PrivateKey(pemRepresentation: authKeyPEM),
    keyIdentifier: "ABC123DEFG",
    teamIdentifier: "DEF123GHIJ"
)
```

Use `.development` for device tokens from debug builds. Call `shutdown()` when your server stops.

Your server has to handle these parts itself:

- **Notification order:** Apple can deliver notifications late or out of order, and the engine applies whatever it is given. Skip data with an older `signedDate` than you have already processed.
- **Which transaction to pass:** `REFUND`, `REVOKE`, `REFUND_DECLINED`, `REFUND_REVERSED` and `CONSUMPTION_REQUEST` carry the one transaction they are about, which can be an earlier billing period. Pass it with the `signedRenewalInfo` from the same notification, including `renewalDate`. The engine uses that date to tell an earlier period from the current one: while the latest purchase is still running the event changes nothing, and once it has run out the subscription is judged as that purchase left it. During a grace period, a notice about an earlier period keeps a subscriber's access and asks for payment, but it never starts a subscription or changes the order's product, because it does not say which product the subscriber is on now. The date is compared with your server's clock, so process a notification when it arrives. If you cannot pass `renewalDate`, call Get All Subscription Statuses and pass the subscription's latest transaction instead.
- **Verification failures:** retry `RETRYABLE_VERIFICATION_FAILURE`, which means Apple's revocation check could not be reached, and return a non-2xx response so Apple resends the notification. Reject everything else.
- **Renewal info:** pass the `signedRenewalInfo` that came with the transaction. It carries the auto-renew status, grace period and billing retry state. Without it, the engine throws `missingRenewalInfo` once the paid period has ended, because it cannot tell an expiry from a grace period.
- **No subscription:** if Apple returns no transactions, pass `AppStoreTransaction()` with `AppStoreRenewalInfo()`, which reports the customer as not subscribed. Only that empty value means this. A transaction with no `productId` but other fields set throws `missingProductID`, and decoding JSON with no `productId` throws.
- **Missed events:** when the date you stored from `accessExpiresAt` passes without a new event, call Get All Subscription Statuses and process the result.

A revocation date on the subscription's latest transaction ends access, including prorated refunds and Family Sharing removals.

#### Receipts

```swift
let result = try await engine.processReceipt(
    notifier: APNSEntitlementNotifier(client: apnsClient, topic: "com.example.app", deviceToken: deviceToken),
    order: order,
    latestReceiptInfo: latestReceiptInfo,
    pendingRenewalInfo: pendingRenewalInfo
)
```

`latestReceiptInfo` and `pendingRenewalInfo` use the `verifyReceipt` format, which Apple has deprecated. Pass the subscription's most recent row of `latest_receipt_info`, with its `pending_renewal_info` entry. Earlier rows end access, because this format cannot show that a later one exists. If Apple returned no purchase, pass `LatestReceiptInfo()`. A row that has fields but no product throws `missingProductID`.

If a response Apple returned with status 0 has no `pending_renewal_info` entry for a lapsed subscription, Apple has stopped renewing it. Pass `PendingRenewalInfo(originalTransactionId: row.originalTransactionId, autoRenewStatus: "0")`, which ends access as a plain expiry. Never do this because your own lookup found nothing.

### Google Play

Call `purchases.subscriptionsv2.get` when you receive a real-time developer notification, and pass its response to the engine. Always pass a purchase you have just fetched, never a stored copy: while Play is still collecting a renewal payment the engine leaves the order alone and waits for Play's next state, which a stored copy never shows. If Play sells one product with several base plans, use the base plan IDs as the product IDs.

```swift
let notifier = FCMEntitlementNotifier(
    projectID: "my-firebase-project",
    registrationToken: registrationToken,
    accessTokenProvider: tokenProvider
)

let purchase = try JSONDecoder().decode(GooglePlaySubscriptionPurchase.self, from: response)

let result = try await engine.processGooglePlayPurchase(
    notifier: notifier,
    order: order,
    purchase: purchase,
    isRevoked: notificationType == subscriptionRevoked
)
```

Your server has to handle these parts itself:

- **Access tokens:** implement `FCMAccessTokenProvider` with your service account, and cache tokens there.
- **Revocations:** pass `isRevoked: true` for `SUBSCRIPTION_REVOKED`, and only for that notification. Google reports revocations as a plain expiry, so the purchase alone cannot show one. The engine ends access whatever state the purchase is in.
- **Acknowledgement:** acknowledge a purchase when `purchase.needsAcknowledgement` is `true` and the result's `accessExpiresAt` has a value, which means this purchase is what gives access. Google refunds purchases that are not acknowledged within three days. The flag is `false` for a purchase that is still pending, which Google refuses to acknowledge. A purchase the engine did not grant, such as one for a product outside your three, is not yours to acknowledge here.
- **Replaced subscriptions:** whenever `purchase.linkedPurchaseToken` is set (an upgrade, downgrade, resubscribe before expiry, or prepaid top-up), move the order to the new purchase token and stop passing the old token's purchases. The engine only ignores an old token when Google marks it as replaced, which it does not do for prepaid plans.
- **Deferred plan changes:** a plan that has not started yet has no expiry, and is ignored until it does. The customer stays on their current plan without an expiry warning.
- **Base plan IDs:** a base plan ID matches under any Play product, so keep the three you use, and any you list in `retiredProductIDs`, unique across the app's subscription products.
- **Test purchases:** `purchase.isTestPurchase` is exposed so you can decide how to treat them.

## Behavior

| Situation | Access | Push |
| --- | --- | --- |
| Active or renewed | Yes | Only for a new subscriber or a product change |
| Trial or intro offer | Yes | When it starts |
| Auto-renew off, 24 hours or less left | Yes | Expiry warning |
| Grace period | Yes | Payment issue |
| Apple billing retry, no grace period left | No | Payment issue |
| Google account hold | No | Payment issue |
| Google pause | No | None |
| Expired | No | None |
| Refunded or revoked | No | Cancelled |
| No subscription (Apple returned no transactions) | No | Not subscribed, if they were subscribed |
| Upgraded (Apple) | Unchanged | Thank you, while the order still holds the replaced product |
| An earlier billing period, while the latest purchase is running (Apple, with `renewalDate`) | Unchanged | None |
| Renewal payment still being collected (Google) | Unchanged | None |
| Pending or replaced (Google) | Unchanged | None |
| A product outside your three | Unchanged | None |

Events for other products are safe to pass in. A refunded consumable, a one-time purchase or another subscription lapsing leaves the order alone.

A product you have retired keeps the subscriber who is already on it. Their renewals keep access, and their expiry or refund ends it. It never starts a subscription for an order that does not hold it.

A payment failure also turns access off: an Apple billing retry, a Google account hold or a pause. For a retired product the engine cannot turn it back on by itself when the store recovers the payment, because nothing but the order says the product was ever yours. List the product in `retiredProductIDs` when you create the engine, and an order that holds it gets access back whenever the store reports a running period, without a welcome message. Listing only helps an order that already holds the product. A customer who can still switch into it from another plan falls under the three-plan limit below.

```swift
let engine = EntitlementEngine(
    storeDelegate: OrderStore(),
    weeklyProductID: "com.example.weekly",
    monthlyProductID: "com.example.monthly.2026",
    yearlyProductID: "com.example.yearly",
    retiredProductIDs: ["com.example.monthly"]
)
```

Grace period and expiry warnings repeat each time you process that state. The upgrade thank-you repeats until the new product is saved on the order. They carry a stable ID, so a new copy replaces the old one on the device, but you should still process on store events rather than on a short timer. Every other message is sent when the order changes, and is not resent if that push fails. To resend one yourself, use `result.notification` with `EntitlementMessages.payload(for:)`.

### Errors

A process call throws before anything is saved, or rethrows what your delegate threw. `EntitlementError` can gain cases in a later release, so end a `switch` over it with `@unknown default`. The same goes for `FCMError`, `PushTransportError` and `EntitlementNotification`.

| Error | Cause | What to do |
| --- | --- | --- |
| `invalidDate(field:)` | A date the decision depends on is missing or malformed | Check how the payload was decoded or mapped |
| `transactionMismatch` | The transaction and its renewal info name different subscriptions | Pass the renewal info that came with that transaction |
| `missingRenewalInfo` | A lapsed Apple period arrived with empty renewal info | Pass the renewal info Apple returned. For a receipt with no entry, see [Receipts](#receipts) |
| `missingProductID` | An Apple transaction or receipt row has fields but no product | Fix the mapping. Pass the empty value only when Apple returned none |
| `unsupportedState(_:)` | Google returned a subscription state this version does not know | Update the package |
| Your delegate's error | The save failed | Retry the event |

Decoding `AppStoreTransaction` or `AppStoreRenewalInfo` throws a `DecodingError` on malformed JSON, before the engine is involved.

A failed push never throws. It comes back in `pushFailure`:

- **APNs refused it:** an `APNSError`. Status 410 means the token is no longer valid, so stop using it. The type comes from `APNSCore` in [APNSwift](https://github.com/kylebrowning/APNSwift), so add that package and `import APNSCore` to match on it.
- **FCM refused it:** an `FCMError`. `.unregistered` means the token is no longer valid. `.requestFailed` carries FCM's error code and the `Retry-After` wait when Google sent one.
- **It could not be sent or was never answered:** a `PushTransportError` from the included clients: `.timeout`, `.connection` or `.invalidRequest`.
- **Your own code:** whatever your `FCMAccessTokenProvider` or custom notifier threw.

## Limits and what your server owns

- **One order per store.** Each store only knows about its own subscription. If an account can buy on both, keep one `Order` for each, and treat the account as subscribed when either is. With one shared order, the App Store ending a lapsed subscription would end a paid Google one.
- **Which fields the engine owns.** It reads and writes `isSubscribed`, `productName` and `updatedAt`. `productName` holds the store product ID, and the engine uses it to recognise the subscription's later events, so do not write anything else there.
- **Two events at once.** The engine does not lock an order, so process one order's events one at a time, loading the order just before each call. As a second line of defence your delegate receives the order being replaced: compare it with what is stored and throw on a mismatch, and the store redelivers the event. That check alone is not enough, because an event that changes nothing on a stale copy never reaches the delegate.
- **Several devices.** A notifier reaches one device. To reach all of an account's devices, write an `EntitlementNotifier` that sends to each of them.
- **Languages.** `EntitlementMessages` holds one set of copy per engine. To localize per user, create an engine per language, or write a notifier that picks its own copy from the notification it is given.
- **Missed expiry.** The order has no expiry date. Store `accessExpiresAt` from the result, and re-check with the store when it passes without a new event.
- **The clock.** An expiry is judged by the server's clock, so keep it synchronized.
- **Three plans.** Every product in the subscription group has to be one of the three. If a customer can switch to a fourth, its events are ignored and the order stays as it was.

## Push delivery

- **Wire format.** On APNs the copy is sent as the alert, and again as `title`, `subtitle`, `body` and `data` at the root of the payload for the app to read. APNs allows 4 KB in all, which leaves about 2.7 KB for `data` with the default copy. On FCM the copy goes in the notification, with the subtitle folded into the body, and `data` is sent base64-encoded as the data field `payload`.
- **Replacing a repeat.** Each `EntitlementNotification` has a stable `collapseID`. It is sent as the APNs collapse ID and as the Android notification tag, so a repeat replaces the copy already on screen.
- **Size.** FCM allows 4 KB for a message too. The engine does not check either limit, so a payload that is too large comes back in `pushFailure`.
- **Custom delivery.** Implement `EntitlementNotifier` to deliver another way. It is told which notification it is sending.
- **Connections.** `HTTPConnectionAPNSClient` reuses its connection and replaces it after two minutes without a push, so a gateway that forgets idle connections does not lose the next one. A new APNs connection takes one request at a time until Apple raises its limit, so pushes sent in parallel on a cold client each open their own connection. To avoid that, let one push finish before sending many, both on a new client and after two idle minutes. The default FCM transport shares one client for the life of the process, with the same two-minute rule.

## Changes

See the [changelog](./CHANGELOG.md) for what changed in each release, including what to change when moving from the untagged versions to 1.0.0.

## Contributing

Contributions are welcome! If you have suggestions for improvements or find bugs, please open an issue or submit a pull request. To report a security problem, see the [security policy](./SECURITY.md).

## License

This package is licensed under the MIT License. See the [LICENSE](./LICENSE.md) file for more information.

## Contact

For any inquiries or support, please contact [support@needletails.com](mailto:support@needletails.com).
