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
    @State private var showUnsyncedWarning = false
    
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
                // Hosted by GitHub Pages from docs/privacy/ on the main branch.
                Link("Privacy Policy", destination: URL(string: "https://ariq100.github.io/Book-Marker/privacy/")!)
            }
            
            Section {
                Button(role: .destructive) {
                    showDeleteAccountConfirmation = true
                    deleteConfirmationText = ""
                } label: {
                    Text("Delete Account")
                }
            } footer: {
                Text("Deleting your account permanently erases it along with all of your books, quotes and words, on this device and on our servers. This cannot be undone.")
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
        .alert("Unsynced Changes", isPresented: $showUnsyncedWarning) {
            Button("Sign Out Anyway", role: .destructive) {
                handleSignOut(force: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Some of your books, quotes or words haven't been saved to your account yet — check your connection. Signing out now will remove them from this device.")
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
            Text("This permanently deletes your account and all of your books, quotes and vocabulary words from our servers and this device. It cannot be undone.")
        }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An error occurred.")
        }
    }
    
    private func handleSignOut(force: Bool = false) {
        isProcessing = true
        Task {
            // Push anything still pending while the session is valid; signing out wipes the
            // local store so the next account on this device can't see this one's data.
            await SyncManager.shared.syncNow()
            if !force && SyncManager.shared.hasUnsyncedChanges() {
                isProcessing = false
                showUnsyncedWarning = true
                return
            }
            do {
                try await AuthManager.shared.signOut()
                SyncManager.shared.resetLocalData()
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
                SyncManager.shared.resetLocalData()
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
            isProcessing = false
        }
    }
}
