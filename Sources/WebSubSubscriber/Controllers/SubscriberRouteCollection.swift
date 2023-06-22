//
//  SubscriberRouteCollection.swift
//
//  Copyright (c) 2023 WebSubKit Contributors
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import FeedKit
import FluentKit
import Foundation
import SwiftSoup
import Vapor


public protocol SubscriberRouteCollection:
        RouteCollection,
        PreparingToSubscribe,
        PreparingToUnsubscribe,
        Subscribing,
        Discovering
    {
    
    var path: PathComponent { get }
    
    func setup(routes: RoutesBuilder, middlewares: [Middleware]) throws
    
    func subscribe(req: Request) async throws -> Response
    
    func handle(req: Request) async throws -> Response
    
    func payload(for subscription: Subscription, on req: Request) async throws -> Response
    
    func verify(req: Request) async throws -> Response
    
    func verify(req: Request) async -> Result<Subscription.Verification, Error>
    
    func verify(_ verification: Subscription.Verification, on req: Request) async -> Result<Subscription.Verification, Error>
    
}


extension SubscriberRouteCollection {
    
    public func boot(routes: RoutesBuilder) throws {
        try self.setup(routes: routes)
    }
    
    public func setup(routes: RoutesBuilder, middlewares: [Middleware] = []) throws {
        let couldBeMiddlewaredRoute = routes.grouped(middlewares)
        couldBeMiddlewaredRoute.get("subscribe", use: subscribe)
        let routesGroup = routes.grouped(path)
        routesGroup.group("callback") { routeBuilder in
            routeBuilder.group(":id") { subBuilder in
                subBuilder.get(use: verify)
                subBuilder.post(use: handle)
            }
        }
    }
    
    public func subscribe(req: Request) async throws -> Response {
        switch (
            Result { try req.query.decode(SubscribeRequest.self) }
        ) {
        case .success(let request):
            let mode = request.mode ?? .subscribe
            switch mode {
            case .subscribe:
                return try await self.subscribe(request, on: req, then: self)
            case .unsubscribe:
                return try await self.unsubscribe(request, on: req, then: self)
            }
        case .failure(let reason):
            return try await ErrorResponse(
                code: .badRequest,
                message: reason.localizedDescription
            ).encodeResponse(status: .badRequest, for: req)
        }
    }
    
    public func handle(req: Request) async throws -> Response {
        req.logger.info(
            """
            Incoming request: \(req.id)
            attempting to handle payload: \(req.body)
            """
        )
        switch try await req.validSubscription() {
        case .success(let subscription):
            req.logger.info(
                """
                Payload for validated subscription: \(subscription)
                from request: \(req.id)
                """
            )
            return try await self.payload(for: subscription, on: req)
        case .failure:
            req.logger.info(
                """
                Payload rejected from request: \(req.id)
                """
            )
            return Response(status: .notAcceptable)
        }
    }
    
    public func verify(req: Request) async throws -> Response {
        return await handle(req, with: self.verify) { attempt in
            Response(status: .accepted, body: .init(stringLiteral: attempt.challenge))
        }
    }
    
    public func verify(req: Request) async -> Result<Subscription.Verification, Error> {
        switch (
            Result { try req.query.decode(SubscriptionVerificationRequest.self) }
                .mapError { _ in return HTTPResponseStatus.badRequest }
        ) {
        case .success(let attempt):
            return await self.verify(attempt, on: req)
        case .failure(let reason):
            return .failure(reason)
        }
    }
    
    public func verify(_ verification: Subscription.Verification, on req: Request) async -> Result<Subscription.Verification, Error> {
        do {
            req.logger.info(
                """
                A hub attempting to: \(verification.mode)
                verification for topic: \(verification.topic)
                with challenge: \(verification.challenge)
                via callback: \(req.url.string)
                """
            )
            guard let subscription = try await req.findRelatedSubscription() else {
                return .failure(HTTPResponseStatus.notFound)
            }
            if subscription.topic != verification.topic {
                return try await self.verification(verification, failure: subscription, on: req)
            }
            return try await self.verification(verification, success: subscription, on: req)
        } catch {
            return .failure(error)
        }
    }
    
}


extension SubscriberRouteCollection {
    
    func verification(_ verification: Subscription.Verification, success subscription: SubscriptionModel, on req: Request) async throws -> Result<Subscription.Verification, Error> {
        subscription.state = .verified
        subscription.leaseSeconds = verification.leaseSeconds
        if let unwrappedLeaseSeconds = verification.leaseSeconds {
            subscription.expiredAt = Calendar.current.date(byAdding: .second, value: unwrappedLeaseSeconds, to: Date())
        }
        subscription.lastSuccessfulVerificationAt = Date()
        try await subscription.save(on: req.db)
        req.logger.info(
            """
            Subscription verified: \(subscription)
            """
        )
        return .success(verification)
    }
    
    func verification(_ verification: Subscription.Verification, failure subscription: SubscriptionModel, on req: Request) async throws -> Result<Subscription.Verification, Error> {
        subscription.state = .unverified
        subscription.lastUnsuccessfulVerificationAt = Date()
        try await subscription.save(on: req.db)
        req.logger.info(
            """
            Subscription not verified: \(subscription)
            """
        )
        return .failure(HTTPResponseStatus.notFound)
    }
    
    @available(*, unavailable, renamed: "Subscriptions.create")
    func saveSubscription(
        topic: String,
        hub: String,
        callback: String,
        state: Subscription.State,
        on req: Request
    ) async throws -> Subscription {
        let subscription = SubscriptionModel(
            topic: topic,
            hub: hub,
            callback: callback,
            state: state
        )
        try await subscription.save(on: req.db)
        return subscription
    }
    
}


// MARK: - Verify Attempt Request

fileprivate struct SubscriptionVerificationRequest: Subscription.Verification {
    
    let mode: Subscription.Verification.Mode
    
    let topic: String
    
    let challenge: String
    
    let leaseSeconds: Int?
    
}


extension SubscriptionVerificationRequest: Codable {
    
    enum CodingKeys: String, CodingKey {
        case mode = "hub.mode"
        case topic = "hub.topic"
        case challenge = "hub.challenge"
        case leaseSeconds = "hub.lease_seconds"
    }
    
}


// MARK: - Utilities Extension

extension Request {
    
    func findRelatedSubscription() async throws -> SubscriptionModel? {
        return try await SubscriptionModel.query(on: self.db)
            .filter("callback", .equal, self.extractCallbackURLString())
            .first()
    }
    
    func validSubscription() async throws -> Result<Subscription, Error> {
        if let subscription = try await self.subscriptionFromHeaders() {
            return .success(subscription)
        }
        if let subscription = try await self.subscriptionFromContent() {
            return .success(subscription)
        }
        return .failure(HTTPResponseStatus.notAcceptable)
    }
    
    func subscriptionFromHeaders() async throws -> Subscription? {
        guard let subscription0 = try await self.findRelatedSubscription() else {
            return nil
        }
        guard let subscription1 = self.headers.extractWebSubLinks() else {
            return nil
        }
        if subscription0.topic == subscription1.topic && subscription0.hub == subscription1.hub {
            return subscription0
        }
        return nil
    }
    
    func subscriptionFromContent() async throws -> Subscription? {
        guard let subscription0 = try await self.findRelatedSubscription() else {
            return nil
        }
        guard let subscription1 = self.body.string?.extractWebSubLinks() else {
            return nil
        }
        if subscription0.topic == subscription1.topic && subscription0.hub == subscription1.hub {
            return subscription0
        }
        return nil
    }
    
    func generateCallbackURLString() -> String {
        return "\(Environment.get("WEBSUB_HOST") ?? "")\(self.url.path.dropSuffix("/subscribe"))/callback/\(UUID().uuidString)"
    }
    
    func extractCallbackURLString() -> String {
        return "\(Environment.get("WEBSUB_HOST") ?? "")\(self.url.path)"
    }
    
}


// MARK: - String Extensions

fileprivate extension String {
    
    func dropSuffix(_ suffix: String) -> String {
        guard self.hasSuffix(suffix) else { return self }
        return String(self.dropLast(suffix.count))
    }
    
}
