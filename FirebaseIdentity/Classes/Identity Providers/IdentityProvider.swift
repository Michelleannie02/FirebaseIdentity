//
//  IdentityProvider.swift
//  Firebase Identity
//
//  Created by Christian Gossain on 2019-02-19.
//  Copyright © 2019 MooveFit Technologies Inc. All rights reserved.
//

import Foundation
import FirebaseAuth

public protocol IdentityProvider {
    /// The provider ID of the receiver.
    var providerID: IdentityProviderID { get }
    
    /// Starts the identity providers sign up routine.
    func signUp(completion: @escaping AuthDataResultCallback)
    
    /// Starts the identity providers sign in routine.
    func signIn(completion: @escaping AuthDataResultCallback)
    
    /// Reauthenticates the cached current user, with the receivers credentials.
    func reauthenticate(completion: @escaping AuthDataResultCallback)
    
//    /// Starts the identity providers link routine. Must be signed in to a Firebase account.
//    func link(completion: @escaping AuthDataResultCallback)
}
