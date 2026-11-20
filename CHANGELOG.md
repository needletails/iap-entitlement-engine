# Changelog

This project follows [Semantic Versioning](https://semver.org).

## 1.0.0

The first tagged release. Everything below is a change from the untagged versions.

### Changed, and your code has to change

- **Process methods return an `EntitlementResult`.** They used to return an HTTP status that was always `.ok`. The result carries the order, whether it was saved, when access ends, the message that was due and why a push failed.
- **A failed push no longer throws.** A throw now means nothing was saved. A push that failed after the save comes back in `pushFailure`, so a dead device token cannot turn an applied event into a store retry.
- **`orderId:` is gone.** It had to equal `order.id`. `EntitlementError.invalidOrderID` went with it.
- **`EntitlementStoreDelegate` has one new requirement:** `updateOrder(_:replacing:)`. It replaces `updateOrder(new:id:)`, and passes the order being replaced so your store can refuse a write that raced with another.
- **`EntitlementNotifier.send` is told which notification it carries:** `send(_:for:expiresAt:)` replaces `send(_:collapseID:expiresAt:)`. Use `notification.collapseID` where you used the string.
- **`processReceipt(apns:)` is removed,** with the engine's `apnTopic` and `deviceToken` and `EntitlementError.missingAPNsConfiguration`. It pushed every call to one engine-wide device. Use `processReceipt(notifier:)` with an `APNSEntitlementNotifier`.
- **The engine's stored properties and `currentDate` are no longer public.** `SubscriptionSnapshot` and `ProductCatalog` are internal, and `IAPTopic` is removed. No public API used them.
- **`HTTPConnectionAPNSClient` and `HTTPConnectionFCMTransport` no longer take a `client:`.** They own their connections. `AsyncHTTPClientFCMTransport` was replaced by `HTTPConnectionFCMTransport` earlier.
- **The included clients throw `PushTransportError`** for a push that could not be sent or was never answered. They used to throw HTTPConnectionKit's own error type.
- **`APNSEntitlementNotifier` is no longer generic.** It takes `any APNSClientProtocol`, so remove the type argument if you wrote one.
- **`FCMError.requestFailed` carries FCM's error code and the `Retry-After` wait.** `FCMTransportResponse` has a `headers` field.
- **`EntitlementError`, `FCMError`, `PushTransportError` and `EntitlementNotification` can gain cases in a later release.** End a `switch` over one of them with `@unknown default`.
- **`AppStoreRenewalInfo` has `renewalDate`.** Pass it, so the engine can tell an earlier billing period from the current one.

### Added

- `retiredProductIDs` on the engine, for products you no longer sell that still have subscribers. An order on a listed product gets access back after a billing retry, an account hold or a pause.
- `EntitlementMessages.payload(for:)` is public, so a failed push can be resent with the same copy.
- `EntitlementResult` has a public initializer, for a test double of the engine.
- `LatestReceiptInfo` and `PendingRenewalInfo` are `Equatable`.

### Fixed

- An event for a product outside your three no longer ends the subscription or sends a push. A one-time purchase no longer throws `invalidDate`.
- A subscriber on a product you have retired keeps access while they renew. They used to be cut off and told they had no subscription. Their expiry or refund still ends access, including for a retired Google base plan.
- A refund of an earlier billing period no longer ends the current one, when the renewal info carries `renewalDate`. Any other notification about an earlier period is left alone in the same way, for as long as the latest purchase is running. An earlier period never starts a subscription or changes the order's product.
- A lapsed Apple transaction or receipt passed with empty renewal info throws `missingRenewalInfo`. It used to end access, even during a grace period. Missing auto-renew status no longer triggers the expiry warning.
- `AppStoreTransaction` no longer decodes JSON with no `productId`, and a transaction or receipt row that has fields but no product throws `missingProductID`. They used to read as "no subscription" and end access.
- A Google purchase with a deferred plan change no longer throws. The plan that has not started is ignored.
- A Google purchase that is still `ACTIVE` just after its expiry time, while Play collects the renewal payment, no longer ends access.
- `needsAcknowledgement` is `false` for a pending or expired Google purchase, which Google refuses to acknowledge.
- An empty product ID slot is no longer treated as a product.
- A subscribed order that names no product is adopted quietly. It used to be welcomed a second time.
- The upgrade thank-you is only sent while the order still holds the replaced product.
- A lapsed Apple subscription in billing retry gets the payment issue push when access ends. It used to end silently.
- `LatestReceiptInfo` decodes rows for purchases that are not subscriptions.
- Errors are thrown. `processReceipt` used to log them and report success.

### Push delivery

- The APNs client speaks HTTP/2 only. Trying HTTP/3 first could hide a failed connection behind a 30 second wait.
- Idle connections are replaced after two minutes, so a gateway that forgets idle connections does not lose the next push.
- FCM messages set an Android notification tag, so a repeated message replaces the one on screen.
- The APNs payload no longer escapes slashes, which wasted part of the 4 KB limit.
- Pushes carry a real expiry. They used to be sent as already expired.
- The default notification copy changed. Use `EntitlementMessages` to set your own.

### Dependencies

- AsyncHTTPClient is no longer used. All requests go through HTTPConnectionKit.
- `needletail-logger` is no longer a dependency, and the engine no longer writes a log line for every call.
- APNSwift is fetched from `https://github.com/kylebrowning/APNSwift.git`, where the repository now lives. If your package names the old `swift-server-community` address, switch to this one, or SwiftPM warns about two addresses for one package.
- `swift-crypto` 5.0.3 or later is required.
