//
//  AuthenticationError.swift
//  Firebase Identity
//
//  Created by Christian Gossain on 2019-02-24.
//

import Foundation

public enum AuthenticationType {
    case signUp
    case signIn
    case reauthenticate
    case linkProvider
}

public enum AuthenticationError: Error {
    /// The context in which the error occurred.
    public struct Context {
        /// The identity provider that was used to authenticate.
        public let providerID: IdentityProviderID
        
        /// The type of authentication that was attempted.
        public let authenticationType: AuthenticationType
        
        /// Creates a new context with the given identity provider and authentication type.
        ///
        /// - parameters:
        ///     - providerID: The identity provider that was used to authenticate.
        ///     - authenticationType: The type of authentication that was attempted.
        public init(providerID: IdentityProviderID, authenticationType: AuthenticationType) {
            self.providerID = providerID
            self.authenticationType = authenticationType
        }
    }
    
    /// Can be trigged by Firebase errors 17007, 17009, 17012
    ///
    /// An indication that there the email address associated with the attempted identity provider is
    /// already in use by another account.
    ///
    /// This case can be handled by signing into the existing account using one of the auth providers specified by this
    /// error and then linking the attempted credentials (available in the identity provider in the error context)
    ///
    /// As associated values, this case contains the list of available auth providers associated with
    /// the existing account and context for debugging.
    case requiresAccountLinking([IdentityProviderID], AuthenticationError.Context)
    
    /// Can be trigged by Firebase errors 17009, 17011
    ///
    /// An indication that an invalid email or password was provided during sign-in.
    ///
    /// As an associated value, this case contains the context for debugging.
    case invalidEmailOrPassword(AuthenticationError.Context)
    
    /// Can be trigged by Firebase error 17007
    ///
    /// An indication that an email based sign-up was attempted, but an email based account already
    /// exists with the same email address.
    ///
    /// As an associated value, this case contains the context for debugging.
    case emailBasedAccountAlreadyExists(AuthenticationError.Context)
    
    /// Can be trigged by Firebase error 17015
    ///
    /// An indication that an attempt was made to link a provider that is already linked to another account.
    /// UserInfo:?
    ///
    /// As an associated value, this case contains the context for debugging.
    case providerAlreadyLinked(AuthenticationError.Context)
    
    /// An indication that a general error has occured.
    ///
    /// As associated values, this case contains the error message and context for debugging.
    case other(String, AuthenticationError.Context)
}

extension AuthenticationError {
    public var localizedDescription: String {
        switch self {
        case .requiresAccountLinking(let providerID, let context):
            let msg = "Account linking required.\n\n\(providerID) \(context)"
            return msg
        case .invalidEmailOrPassword(let context):
            let msg = "Invalid email or password.\n\n\(context)"
            return msg
        case .emailBasedAccountAlreadyExists(let context):
            let msg = "The email entered is already associated with an account. Please try a different email.\n\n\(context)"
            return msg
        case .providerAlreadyLinked(let context):
            let msg = "A user can only be linked to one identity for the given provider.\n\n\(context)"
            return msg
        case .other(let message, let context):
            let msg = "\(message).\n\n\(context)"
            return msg
        }
    }
}
