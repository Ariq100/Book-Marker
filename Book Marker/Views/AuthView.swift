//
//  AuthView.swift
//  Book Marker
//
//  TASK 3

import SwiftUI
import AuthenticationServices

struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert = false
    
    // Inline validation states
    @State private var emailError: String? = nil
    @State private var passwordError: String? = nil
    
    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        SignInWithAppleButton(
                            .signIn,
                            onRequest: { request in
                                // AuthManager uses its own ASAuthorizationController,
                                // but we can also trigger it from here. We are using AuthManager.signInWithApple().
                                // Actually, SignInWithAppleButton has its own UI mechanism. Let's just use a regular button
                                // styled like SignInWithAppleButton to trigger our AuthManager flow, or use the SignInWithAppleButton's default closure.
                                // The requirement says: "using SignInWithAppleButton from AuthenticationServices styled for SwiftUI"
                                // We can leave the request and onCompletion empty and intercept the tap if possible, 
                                // but SignInWithAppleButton doesn't support a simple action closure.
                                // Instead, we can use the environment \.authorizationController if we want, but AuthManager has it.
                            },
                            onCompletion: { _ in }
                        )
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 50)
                        .overlay {
                            // Overlay a transparent button to use our AuthManager implementation
                            Button(action: {
                                handleAppleSignIn()
                            }) {
                                Color.clear
                            }
                        }
                    } footer: {
                        Text("Or use email and password")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top)
                    }
                    
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .onChange(of: email) { _ in validateEmail() }
                        
                        if let emailError {
                            Text(emailError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        SecureField("Password", text: $password)
                            .textContentType(isSignUp ? .newPassword : .password)
                            .onChange(of: password) { _ in validatePassword() }
                        
                        if let passwordError {
                            Text(passwordError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    
                    Section {
                        Button {
                            handleEmailAuth()
                        } label: {
                            Text(isSignUp ? "Sign Up" : "Sign In")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .disabled(!isFormValid)
                        
                        Button {
                            withAnimation {
                                isSignUp.toggle()
                                emailError = nil
                                passwordError = nil
                            }
                        } label: {
                            Text(isSignUp ? "Already have an account? Sign In" : "Don't have an account? Sign Up")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .font(.footnote)
                        }
                    }
                }
                .disabled(isLoading)
                
                if isLoading {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Please wait...")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                        .shadow(radius: 10)
                }
            }
            .navigationTitle(isSignUp ? "Create Account" : "Welcome Back")
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "Something went wrong, please try again.")
            }
        }
    }
    
    // MARK: - Validation
    
    private var isFormValid: Bool {
        validateEmail(updateUI: false) && validatePassword(updateUI: false)
    }
    
    @discardableResult
    private func validateEmail(updateUI: Bool = true) -> Bool {
        if email.isEmpty {
            if updateUI { emailError = "Email is required" }
            return false
        }
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let predicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        let isValid = predicate.evaluate(with: email)
        if updateUI {
            emailError = isValid ? nil : "Invalid email format"
        }
        return isValid
    }
    
    @discardableResult
    private func validatePassword(updateUI: Bool = true) -> Bool {
        if password.isEmpty {
            if updateUI { passwordError = "Password is required" }
            return false
        }
        if password.count < 8 {
            if updateUI { passwordError = "Password must be at least 8 characters" }
            return false
        }
        if updateUI { passwordError = nil }
        return true
    }
    
    // MARK: - Actions
    
    private func handleAppleSignIn() {
        isLoading = true
        Task {
            do {
                try await AuthManager.shared.signInWithApple()
            } catch {
                handleError(error)
            }
            isLoading = false
        }
    }
    
    private func handleEmailAuth() {
        validateEmail()
        validatePassword()
        guard isFormValid else { return }
        
        isLoading = true
        Task {
            do {
                if isSignUp {
                    try await AuthManager.shared.signUpWithEmail(email: email, password: password)
                    errorMessage = "Please check your email to confirm your account."
                    showErrorAlert = true
                } else {
                    try await AuthManager.shared.signInWithEmail(email: email, password: password)
                }
            } catch {
                handleError(error)
            }
            isLoading = false
        }
    }
    
    private func handleError(_ error: Error) {
        // The underlying error is deliberately never shown to end users (it can carry server
        // internals), but without it in the console every failure looks identical during
        // development — which is exactly how a missing Sign in with Apple entitlement and a
        // disabled Supabase provider both end up as "Something went wrong, please try again."
        #if DEBUG
        print("[AuthView] auth failed: \(error)")
        #endif

        let errorString = String(describing: error).lowercased()
        if errorString.contains("invalid login credentials") || errorString.contains("invalid_credentials") {
            errorMessage = "Invalid email or password. Please try again."
        } else if errorString.contains("user already registered") {
            errorMessage = "An account with this email already exists."
        } else if errorString.contains("email not confirmed") || errorString.contains("email_not_confirmed") {
            errorMessage = "Please confirm your email first — check your inbox for the confirmation link."
        } else if errorString.contains("over_email_send_rate_limit") || errorString.contains("rate limit") {
            errorMessage = "Too many attempts. Please wait a few minutes and try again."
        } else if errorString.contains("unsupported provider") || errorString.contains("provider is not enabled") {
            // Supabase returns this when the Apple provider is disabled for the project.
            errorMessage = "Sign in with Apple isn't available right now. Please use email and password."
        } else if errorString.contains("authorizationerror") || errorString.contains("com.apple.authenticationservices") {
            // ASAuthorizationController failed before Supabase was ever reached — almost always
            // a missing "Sign in with Apple" capability on the target, or an unsigned build.
            errorMessage = "Sign in with Apple isn't available on this build. Please use email and password."
        } else {
            // Generic error message for end users
            errorMessage = "Something went wrong, please try again."
        }
        showErrorAlert = true
    }
}
