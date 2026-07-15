import KumoCoreKit

@MainActor
extension KumoAppStore {
    func loadPreferences() {
        preferences = controller.userPreferences()
        localizationManager?.currentLanguage = preferences.appLanguage
        if !preferences.hasCompletedOnboarding {
            showOnboarding = true
        }
    }

    func updatePreferences(_ next: UserPreferences) {
        do {
            try controller.updateUserPreferences(next)
            preferences = next
            errorMessage = nil
        } catch {
            errorMessage = displayMessage(for: error)
        }
    }

    /// Persists onboarding completion and dismisses the sheet. Called when the
    /// user reaches the final Done step or explicitly skips it.
    func completeOnboarding() {
        var next = preferences
        next.hasCompletedOnboarding = true
        updatePreferences(next)
        showOnboarding = false
    }

    /// Lets Settings reopen the onboarding flow without resetting the
    /// persisted completion flag. The flag will be re-saved when the user
    /// finishes the sheet again.
    func reopenOnboarding() {
        showOnboarding = true
    }
}
