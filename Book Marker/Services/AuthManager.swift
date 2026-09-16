//
//  AuthManager.swift
//  Book Marker
//
//  TASK 2

import Foundation
import Observation
import AuthenticationServices
import Supabase

// CONSTRAINT: All password and token values must never be logged via print() or os_log anywhere in this file.

@Observable
final class AuthManager: NSObject {
    static let shared = AuthManager()
    
    let client: SupabaseClient
    
    var currentUser: User?
    var isAuthenticated: Bool {
        currentUser != nil
    }
    
    private var authStateTask: Task<Void, Never>?
    private var appleSignInContinuation: CheckedContinuation<String, Error>?
    
    override private init() {
        // Initialize SupabaseClient
        self.client = SupabaseClient(
            supabaseURL: SupabaseConfig.projectURL,
            supabaseKey: SupabaseConfig.anonKey
        )
        super.init()
        
        // Listen for Supabase auth state changes
        authStateTask = Task {
            for await state in client.auth.authStateChanges {
                await MainActor.run {
                    self.currentUser = state.session?.user
                }
            }
        }
    }
    
    deinit {
        authStateTask?.cancel()
    }
    
    // MARK: - Sign In with Apple
    
    func signInWithApple() async throws {
        do {
            let idToken = try await performAppleSignIn()
            
            // Exchange identity token with Supabase
            try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken)
            )
        } catch AuthManagerError.appleSignInCanceled {
            // Return silently without throwing
            return
        } catch {
            throw error
        }
    }
    
    @MainActor
    private func performAppleSignIn() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.appleSignInContinuation = continuation
            
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }
    
    // MARK: - Email / Password Auth
    
    func signUpWithEmail(email: String, password: String) async throws {
        // Calls Supabase auth.signUp, requiring email confirmation.
        // User is not auto-signed in until confirmed (depending on Supabase project settings, confirm email is usually required).
        try await client.auth.signUp(
            email: email,
            password: password
        )
    }
    
    func signInWithEmail(email: String, password: String) async throws {
        try await client.auth.signIn(
            email: email,
            password: password
        )
    }
    
    // MARK: - Sign Out & Delete
    
    func signOut() async throws {
        // Calls Supabase auth.signOut() which explicitly deletes any cached session token from the iOS Keychain.
        // Confirming that supabase-swift stores its session in Keychain by default via the SDK's built-in storage.
        // We rely on this default behavior and do not implement a second manual Keychain layer.
        try await client.auth.signOut()
    }
    
    func deleteAccount() async throws {
        // We must call a Supabase Edge Function to delete the account.
        // WHY: Deleting an auth.users row requires the service_role key, which bypasses RLS.
        // The service_role key must NEVER be embedded in a client application for security reasons.
        // Therefore, we invoke an Edge Function using the user's current JWT, and the function
        // (running securely on the server) uses the service_role key to delete the user.
        
        _ = try await client.functions.invoke("delete-account")
        // Optionally handle response
        
        // After successful deletion on the backend, sign out locally
        try await signOut()
    }
}

extension AuthManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
           let identityTokenData = appleIDCredential.identityToken,
           let identityToken = String(data: identityTokenData, encoding: .utf8) {
            appleSignInContinuation?.resume(returning: identityToken)
        } else {
            appleSignInContinuation?.resume(throwing: URLError(.badServerResponse))
        }
        appleSignInContinuation = nil
    }
    
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            // Handle cancelation silently by not throwing, effectively just returning without error.
            // In a continuation, returning normally isn't easily mapped if we are supposed to throw,
            // but we can throw a specific silent error or just complete the continuation with an empty token (which will fail later)
            // Wait, the requirement: "Handle the case where the user cancels the Apple sign-in sheet by returning silently without throwing, not showing an error."
            // We need to return an empty string or something, but signInWithIdToken will fail with empty string.
            // Let's create a custom cancellation error that we catch in signInWithApple.
            appleSignInContinuation?.resume(throwing: AuthManagerError.appleSignInCanceled)
        } else {
            appleSignInContinuation?.resume(throwing: error)
        }
        appleSignInContinuation = nil
    }
}

enum AuthManagerError: Error {
    case appleSignInCanceled
}

