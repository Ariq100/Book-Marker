//
//  SettingsView.swift
//  Book Marker
//
//  TASK 5

import SwiftUI

struct SettingsView: View {
    @State private var showSignOutConfirmation = false
    @State private var showDeleteAccountConfirmation = false
    @State private var deleteConfirmationText = ""
    @State private var isProcessing = false
    @State private var errorMessage: String? = nil
    @State private var showErrorAlert = false
    
    var body: some View {
        Form {
            Section(header: Text("Account")) {
                if let email = AuthManager.shared.currentUser?.email {
                    HStack {
                        Text("Email")
                        Spacer()
                        Text(email)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Not signed in")
                        .foregroundColor(.secondary)
                }
                
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    Text("Sign Out")
                }
            }
            
            Section(header: Text("About")) {
                // TODO: Replace with your actual Privacy Policy URL
                Link("Privacy Policy", destination: URL(string: "https://example.com/privacy")!)
            }
            
            Section {
                Button(role: .destructive) {
                    showDeleteAccountConfirmation = true
                    deleteConfirmationText = ""
                } label: {
                    Text("Delete Account")
                }
            } footer: {
                Text("Deleting your account is permanent and cannot be undone.")
            }
        }
        .navigationTitle("Settings")
        .disabled(isProcessing)
        .overlay {
            if isProcessing {
                ProgressView()
            }
        }
        .confirmationDialog(
            "Are you sure you want to sign out?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                handleSignOut()
            }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Delete Account", isPresented: $showDeleteAccountConfirmation) {
            TextField("Type DELETE to confirm", text: $deleteConfirmationText)
                .autocapitalization(.allCharacters)
            
            Button("Delete", role: .destructive) {
                handleDeleteAccount()
            }
            .disabled(deleteConfirmationText != "DELETE")
            
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action is irreversible. All your data will be permanently deleted.")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An error occurred.")
        }
    }
    
    private func handleSignOut() {
        isProcessing = true
        Task {
            do {
                try await AuthManager.shared.signOut()
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
            isProcessing = false
        }
    }
    
    private func handleDeleteAccount() {
        isProcessing = true
        Task {
            do {
                try await AuthManager.shared.deleteAccount()
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
            isProcessing = false
        }
    }
}
