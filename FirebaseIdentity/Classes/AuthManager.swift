//
//  AuthManager.swift
//  Firebase Identity
//
//  Created by Christian Gossain on 2019-02-15.
//  Copyright © 2019 MooveFit Technologies Inc. All rights reserved.
//

import Foundation
import FirebaseCore
import FirebaseAuth
import ProcedureKit

public enum Result<Value, Error: Swift.Error> {
    case success(Value)
    case failure(Error)
}

public extension Result {
    func resolve() throws -> Value {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

/// The block that is invoked when an authentication related event completes. The parameter
/// passed to the block is an `AuthManager.Result` object that may indicate that a
/// further user action is required.
public typealias AuthResultHandler = (Result<AuthDataResult, AuthenticationError>) -> Void

/// The block that is invoked when a provider unlink event completes.
public typealias AuthUnlinkHandler = (Result<User, Error>) -> Void

/// The block that is invoked when a profile change event completes.
public typealias ProfileChangeHandler = (Result<User, ProfileChangeError>) -> Void

/// An object that provides context about the profile change that triggered the reauthentication challenge.
public struct ProfileChangeReauthenticationChallenge {
    /// The error context that caused the reauthentication challenge to occur.
    public let context: ProfileChangeError.Context
    
    /// Interal use completion handler.
    fileprivate let completion: ProfileChangeHandler
}

public protocol AuthManagerReauthenticating: class {
    /// Called when an action triggers the `requiresRecentLogin` from Firebase.
    ///
    /// - parameters:
    ///     - manager: The auth manager instance that is requesting reauthentication.
    ///     - providers: An array of available/linked providers that should be used for reauthentication. These can either be presented as options to a user, or the first item in the list can automatically be used for reauthentication. The providers are pre-sorted according to the priority order specified in the `providerReauthenticationPriority` property.
    ///     - challenge: An object that must be passed to the auth manager's `reauthenticate` method. This is required to continue/retry the action that triggered the `requiresRecentLogin` error.
    func authManager(_ manager: AuthManager, needsReauthenticationUsing providers: [IdentityProviderUserInfo], challenge: ProfileChangeReauthenticationChallenge)
}

extension AuthManager {
    /// Posted on the main queue when the authentication state changes.
    public static let authenticationStateChangedNotification = Notification.Name("com.firebaseidentity.authmanager.authenticationstatechangednotification")
}

/// An object that manages all Firebase authentication and user related events.
public class AuthManager {
    public enum State {
        case notDetermined
        case notAuthenticated
        case authenticated
    }
    
    /// The shared instance.
    public static let shared = AuthManager()
    
    /// The object that will be used to handle reauthentication.
    public weak var reauthenticator: AuthManagerReauthenticating?
    
    /// The authentication state of the receiver.
    public private(set) var authenticationState = State.notDetermined
    
    /// The currently authenticated user, or nil if user is not authenticated.
    public private(set) var authenticatedUser: User?
    
    /// The list of identity providers associated with the currently authenticated user.
    ///
    /// - note: The providers are returned in sorted by the priority order specified in `providerReauthenticationPriority`.
    public var linkedProviders: [IdentityProviderUserInfo] {
        let providers: [IdentityProviderUserInfo] = authenticatedUser?.providerData.compactMap({
            guard let providerID = IdentityProviderID(rawValue: $0.providerID) else {
                return nil
            }
            return IdentityProviderUserInfo(providerID: providerID, email: $0.email, displayName: $0.displayName)
        }) ?? []
        
        // sort according to the priority order
        // https://stackoverflow.com/a/51683055/485352
        return providers.sorted {
            guard let first = providerReauthenticationPriority.firstIndex(of: $0.providerID) else {
                return false
            }

            guard let second = providerReauthenticationPriority.firstIndex(of: $1.providerID) else {
                return true
            }

            return first < second
        }
    }
    
    /// The order of priority that identity providers should be used for reauthentication when available.
    ///
    /// Defaults to `[.email, .facebook]`.
    public var providerReauthenticationPriority: [IdentityProviderID] = IdentityProviderID.allCases.sorted { (lhs, rhs) -> Bool in return lhs == .email }
    
    
    // MARK: - Private Properties
    /// An internal procedure queue for authentication procedures (i.e. sign-up, sign-in, reauthentication). This primary
    /// purpose for using procedure for authentication is that it provides a way to maintain a strong reference to the
    /// identity provider while the authentication action is in progress.
    private var authenticationProcedureQueue: ProcedureQueue = {
        let queue = ProcedureQueue()
        queue.name = "com.firebaseIdentity.authManager.authenticationProcedureQueue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    
    // MARK: - Lifecycle
    /// Configures the shared AuthManager instance.
    ///
    /// This method should be called shortly after the app is launched after the Firebase services have been configured (i.e. `FirebaseApp.configure()`).
    public static func configure() {
        AuthManager.shared.start()
    }
}

extension AuthManager {
    public func signUp<P: IdentityProvider>(with provider: P, completion: @escaping AuthResultHandler) {
        authenticationProcedureQueue.addOperation(AuthProcedure(provider: provider, authenticationType: .signUp) { (result, error) in
            guard let error = error else {
                completion(.success(result!))
                return
            }
            
            let context = AuthenticationError.Context(providerID: provider.providerID, authenticationType: .signUp)
            self.handleAuthProcedureFirebaseError(error, context: context, provider: provider, completion: completion)
        })
    }
    
    public func signIn<P: IdentityProvider>(with provider: P, completion: @escaping AuthResultHandler) {
        authenticationProcedureQueue.addOperation(AuthProcedure(provider: provider, authenticationType: .signIn) { (result, error) in
            guard let error = error else {
                completion(.success(result!))
                return
            }
            
            let context = AuthenticationError.Context(providerID: provider.providerID, authenticationType: .signIn)
            self.handleAuthProcedureFirebaseError(error, context: context, provider: provider, completion: completion)
        })
    }
    
    public func reauthenticate<P: IdentityProvider>(with provider: P, for challenge: ProfileChangeReauthenticationChallenge, errorHandler: @escaping (AuthenticationError) -> Void) {
        self.reauthenticate(with: provider) { (result) in
            switch result {
            case .success(_):
                // using the information in the challenge object, we can retry the profile change that had previously failed
                switch challenge.context.profileChangeType {
                case .updateEmail(let email):
                    self.updateEmail(to: email, completion: challenge.completion)
                    
                case .updatePassword(let password):
                    self.updatePassword(to: password, completion: challenge.completion)
                    
                default:
                    break // does not need reauthentication
                }
                
            case .failure(let error):
                errorHandler(error)
            }
        }
    }
    
    public func cancelReauthentication(for challenge: ProfileChangeReauthenticationChallenge) {
        challenge.completion(.failure(.cancelledByUser(challenge.context)))
    }
    
    public func linkWith<P: IdentityProvider>(with provider: P, completion: @escaping AuthResultHandler) {
        authenticationProcedureQueue.addOperation(AuthProcedure(provider: provider, authenticationType: .linkProvider) { (result, error) in
            guard let error = error else {
                completion(.success(result!))
                return
            }
            
            let context = AuthenticationError.Context(providerID: provider.providerID, authenticationType: .linkProvider)
            self.handleAuthProcedureFirebaseError(error, context: context, provider: provider, completion: completion)
        })
    }
}

extension AuthManager {
    public func updateDispalyName(to newDisplayName: String, passwordForReauthentication: String? = nil, completion: @escaping ProfileChangeHandler) {
        guard let authenticatedUser = authenticatedUser else {
            return
        }
        
        let profileChangeRequest = authenticatedUser.createProfileChangeRequest()
        profileChangeRequest.displayName = newDisplayName
        profileChangeRequest.commitChanges { (error) in
            guard let error = error else {
                // ensure the user is refreshed
                authenticatedUser.reload(completion: { (_) in
                    // a reload error is irrelevant, the update was successful regardless of the reload
                    completion(.success(authenticatedUser))
                })
                return
            }

            let context = ProfileChangeError.Context(authenticatedUser: authenticatedUser, profileChangeType: .updateDisplayName(newDisplayName))
            self.handleProfileChangeFirebaseError(error, context: context, passwordForReauthentication: passwordForReauthentication, completion: completion)
        }
    }
    
    /// Updates the email address for the user.
    ///
    /// - parameters:
    ///     - newEmail: The new email address for the user.
    ///     - passwordForReauthentication: If provided, this password will be silently used to reauthenticate using the `email` provider (if available) and if the `requiresRecentLogin` Firebase error is triggered. Otherwise, reauthentication occurs via the `reauthenticator` object.
    public func updateEmail(to newEmail: String, passwordForReauthentication: String? = nil, completion: @escaping ProfileChangeHandler) {
        guard let authenticatedUser = authenticatedUser else {
            return
        }

        authenticatedUser.updateEmail(to: newEmail) { (error) in
            guard let error = error else {
                // ensure the user is refreshed
                authenticatedUser.reload(completion: { (_) in
                    // a reload error is irrelevant, the update was successful regardless of the reload
                    completion(.success(authenticatedUser))
                })
                return
            }

            let context = ProfileChangeError.Context(authenticatedUser: authenticatedUser, profileChangeType: .updateEmail(newEmail))
            self.handleProfileChangeFirebaseError(error, context: context, passwordForReauthentication: passwordForReauthentication, completion: completion)
        }
    }
    
    /// Updates (or sets) the password for the user.
    ///
    /// - parameters:
    ///     - newPassword: The new password for the user.
    ///     - passwordForReauthentication: If provided, this password will be silently used to reauthenticate using the `email` provider (if available) and if the `requiresRecentLogin` Firebase error is triggered. Otherwise, reauthentication occurs via the `reauthenticator` object.
    public func updatePassword(to newPassword: String, passwordForReauthentication: String? = nil, completion: @escaping ProfileChangeHandler) {
        guard let authenticatedUser = authenticatedUser else {
            return
        }
        
        authenticatedUser.updatePassword(to: newPassword) { (error) in
            guard let error = error else {
                // ensure the user is refreshed
                authenticatedUser.reload(completion: { (_) in
                    // a reload error is irrelevant, the update was successful regardless of the reload
                    completion(.success(authenticatedUser))
                })
                return
            }
            
            let context = ProfileChangeError.Context(authenticatedUser: authenticatedUser, profileChangeType: .updatePassword(newPassword))
            self.handleProfileChangeFirebaseError(error, context: context, passwordForReauthentication: passwordForReauthentication, completion: completion)
        }
    }
    
    public func unlinkFrom(providerID: IdentityProviderID, completion: @escaping ProfileChangeHandler) {
        guard let authenticatedUser = authenticatedUser else {
            return
        }
        
        authenticatedUser.unlink(fromProvider: providerID.rawValue) { (user, error) in
            guard let error = error else {
                // ensure the user is refreshed
                authenticatedUser.reload(completion: { (_) in
                    // a reload error is irrelevant, the update was successful regardless of the reload
                    completion(.success(authenticatedUser))
                })
                return
            }
            
            let context = ProfileChangeError.Context(authenticatedUser: authenticatedUser, profileChangeType: .unlinkFromProvider(providerID))
            self.handleProfileChangeFirebaseError(error, context: context, completion: completion)
        }
    }
    
    public func deleteAccount(with completion: @escaping ProfileChangeHandler) {
        guard let authenticatedUser = authenticatedUser else {
            return
        }
        
        authenticatedUser.delete { (error) in
            guard let error = error else {
                completion(.success(authenticatedUser))
                return
            }
            
            let context = ProfileChangeError.Context(authenticatedUser: authenticatedUser, profileChangeType: .deleteAccount)
            self.handleProfileChangeFirebaseError(error, context: context, completion: completion)
        }
    }
}

extension AuthManager {
    private func start() {
        Auth.auth().addStateDidChangeListener({ (auth, user) in
            if let user = user {
                self.authenticatedUser = user
                self.authenticationState = .authenticated
            }
            else {
                self.authenticatedUser = nil
                self.authenticationState = .notAuthenticated
            }
            
            NotificationCenter.default.post(name: AuthManager.authenticationStateChangedNotification, object: self, userInfo: nil)
        })
    }
    
    private func reauthenticate<P: IdentityProvider>(with provider: P, completion: @escaping AuthResultHandler) {
        authenticationProcedureQueue.addOperation(AuthProcedure(provider: provider, authenticationType: .reauthenticate) { (result, error) in
            guard let error = error else {
                completion(.success(result!))
                return
            }
            
            let context = AuthenticationError.Context(providerID: provider.providerID, authenticationType: .reauthenticate)
            self.handleAuthProcedureFirebaseError(error, context: context, provider: provider, completion: completion)
        })
    }
    
    private func handleAuthProcedureFirebaseError<P: IdentityProvider>(_ error: Error, context: AuthenticationError.Context, provider: P, completion: @escaping AuthResultHandler) {
        if let error = error as NSError? {
            if error.code == AuthErrorCode.emailAlreadyInUse.rawValue, provider.providerID == .email {
                // this error is only ever is specifically triggered when using the "createUserWithEmail" method
                // in Firebase; in other words, this error is only triggered when the user tries to sign up for
                // an email account
                let email = (provider as! EmailIdentityProvider).email
                Auth.auth().fetchSignInMethods(forEmail: email) { (providers, fetchError) in
                    // note that unless the email address passed to this method, we don't expect
                    // to run into any errors (other than typical network connection errors)
                    
                    // get all providers that are not the one that the user just tried authenticating with
                    if let providers = providers?.compactMap({ IdentityProviderID(rawValue: $0) }).filter({ $0 != provider.providerID }), !providers.isEmpty {
                        completion(.failure(.requiresAccountLinking(providers, context)))
                    }
                    else {
                        completion(.failure(.emailBasedAccountAlreadyExists(context)))
                    }
                }
            }
            else if error.code == AuthErrorCode.wrongPassword.rawValue, provider.providerID == .email {
                let email = (provider as! EmailIdentityProvider).email
                Auth.auth().fetchSignInMethods(forEmail: email) { (providers, fetchError) in
                    // note that unless the email address passed to this method was not provided by the
                    // Firebase error, we don't expect to run into any errors (other than typical
                    // network connection errors)
                    
                    // get all providers that are not the one that the user just tried authenticating with
                    
                    // note this case is a little different from the other potential account linking scenarios
                    // in that the error could actually be a "wrong password" (reported by Firebase error), but
                    // it may also be a situation that requires account linking (a sign in via email was attempted
                    // even though there is no email based account, but there is an account linked to a third
                    // party auth provider that is using the same email) - this scenario can be identified by
                    // detecting the lack of an email based sign in method associated with this email account
                    if let providers = providers?.compactMap({ IdentityProviderID(rawValue: $0) }), !providers.contains(.email) {
                        let nonEmailProviders = providers.filter({ $0 != provider.providerID })
                        completion(.failure(.requiresAccountLinking(nonEmailProviders, context)))
                    }
                    else {
                        completion(.failure(.invalidEmailOrPassword(context)))
                    }
                }
            }
            else if error.code == AuthErrorCode.accountExistsWithDifferentCredential.rawValue {
                let email =  error.userInfo[AuthErrorUserInfoEmailKey] as! String
                Auth.auth().fetchSignInMethods(forEmail: email) { (providers, fetchError) in
                    // note that unless the email address passed to this method, we don't expect
                    // to run into any errors (other than typical network connection errors)
                    
                    // get all providers that are not the one that the user just tried authenticating with
                    if let providers = providers?.compactMap({ IdentityProviderID(rawValue: $0) }).filter({ $0 != provider.providerID }), !providers.isEmpty {
                        completion(.failure(.requiresAccountLinking(providers, context)))
                    }
                    else {
                        let msg = fetchError?.localizedDescription ?? "No error message provided. Account exists with different credential."
                        completion(.failure(.other(msg, context)))
                    }
                }
            }
            else if error.code == AuthErrorCode.userNotFound.rawValue {
                completion(.failure(.invalidEmailOrPassword(context)))
            }
            else if error.code == AuthErrorCode.providerAlreadyLinked.rawValue {
                completion(.failure(.providerAlreadyLinked(context)))
            }
            else {
                let msg = error.localizedDescription
                completion(.failure(.other(msg, context)))
            }
        }
    }
    
    private func handleProfileChangeFirebaseError(_ error: Error, context: ProfileChangeError.Context, passwordForReauthentication: String? = nil, completion: @escaping ProfileChangeHandler) {
        if let error = error as NSError? {
            if error.code == AuthErrorCode.requiresRecentLogin.rawValue {
                if let passwordForReauthentication = passwordForReauthentication, let emailProviderUserInfo = self.linkedProviders.filter({ $0.providerID == .email }).first, let email = emailProviderUserInfo.email {
                    let challenge = ProfileChangeReauthenticationChallenge(context: context, completion: completion)
                    
                    // attempt reauthenticating silently with the provided password
                    let provider = EmailIdentityProvider(email: email, password: passwordForReauthentication)
                    self.reauthenticate(with: provider, for: challenge) { (reauthError) in
                        completion(.failure(.other(reauthError.localizedDescription, context)))
                    }
                }
                else if let reauthenticator = reauthenticator {
                    // 1. notify the delegate that we need to reauthenticate
                    // 2. after a successful reauthentication, we need to continue the profile change and eventually call the completion handler
                    let challenge = ProfileChangeReauthenticationChallenge(context: context, completion: completion)
                    reauthenticator.authManager(self, needsReauthenticationUsing: self.linkedProviders, challenge: challenge)
                }
                else {
                    completion(.failure(.requiresRecentSignIn(context)))
                }
            }
            else if error.code == AuthErrorCode.noSuchProvider.rawValue {
                completion(.failure(.noSuchProvider(context)))
            }
            else {
                let msg = error.localizedDescription
                completion(.failure(.other(msg, context)))
            }
        }
        else {
            let authenticatedUser = context.authenticatedUser
            completion(.success(authenticatedUser))
        }
    }
}
