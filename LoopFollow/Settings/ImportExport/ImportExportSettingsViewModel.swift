// LoopFollow
// ImportExportSettingsViewModel.swift

import Foundation
import SwiftUI

struct ImportPreview {
    let nightscoutURL: String?
    let dexcomUsername: String?
    let remoteType: String?
    let alarmCount: Int
    let alarmNames: [String]
    let apnsKeyId: String?
}

class ImportExportSettingsViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var isShowingQRCodeScanner = false
    @Published var isShowingQRCodeDisplay = false
    @Published var isShowingAlarmSelection = false
    @Published var qrCodeErrorMessage = "" {
        didSet { qrCodeMessageIsSuccess = false }
    }

    /// True when `qrCodeErrorMessage` holds the import success message.
    @Published var qrCodeMessageIsSuccess = false
    @Published var qrCodeString = ""
    @Published var exportType: ExportType = .nightscout
    @Published var exportedAlarmIds: Set<UUID> = []
    @Published var importPreview: ImportPreview?
    @Published var showImportConfirmation = false
    @Published var pendingImportSettings: CombinedSettingsExport?
    @Published var pendingImportSource: String = ""
    @Published var showExportSuccessAlert = false
    @Published var exportSuccessMessage = ""
    @Published var exportSuccessDetails: [String] = []
    @Published var showImportNotFoundAlert = false
    @Published var importNotFoundMessage = ""

    // MARK: - Export Types

    enum ExportType: String, CaseIterable {
        case nightscout = "Nightscout Settings"
        case dexcom = "Dexcom Share Settings"
        case remote = "Remote Settings"
        case apns = "APNS Settings"
        case alarms = "Alarm Settings"

        var icon: String {
            switch self {
            case .nightscout: return "network"
            case .dexcom: return "network"
            case .remote: return "antenna.radiowaves.left.and.right"
            case .alarms: return "bell"
            case .apns: return "key.horizontal"
            }
        }

        var importDescription: String {
            switch self {
            case .nightscout: return String(localized: "Nightscout Settings")
            case .dexcom: return String(localized: "Dexcom Share Settings")
            case .remote: return String(localized: "Remote Settings")
            case .alarms: return String(localized: "Alarm Settings")
            case .apns: return String(localized: "APNS Settings")
            }
        }
    }

    // MARK: - QR Code Methods

    func handleQRCodeScanResult(_ result: Result<String, Error>) {
        DispatchQueue.main.async {
            switch result {
            case let .success(jsonString):
                self.processImportedSettings(jsonString)
            case let .failure(error):
                self.qrCodeErrorMessage = String(localized: "Scanning failed: \(error.localizedDescription)")
            }
            self.isShowingQRCodeScanner = false
        }
    }

    private func processImportedSettings(_ jsonString: String) {
        do {
            LogManager.shared.log(category: .general, message: "Processing QR code data: \(LogRedactor.fingerprint(jsonString))")

            guard let data = jsonString.data(using: .utf8) else {
                qrCodeErrorMessage = String(localized: "Invalid QR code data")
                return
            }

            LogManager.shared.log(category: .general, message: "QR code data converted to Data, size: \(data.count) bytes")

            // Try to decode as JSON first to see what we get
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                let topLevelKeys = (jsonObject as? [String: Any]).map { Array($0.keys).sorted() } ?? []
                LogManager.shared.log(category: .general, message: "JSON parsing successful: keys=\(topLevelKeys)")
            } catch {
                LogManager.shared.log(category: .general, message: "JSON parsing failed: \(error.localizedDescription)")
            }

            // Use migration manager to handle version compatibility
            guard let settings = SettingsMigrationManager.migrateSettings(data) else {
                LogManager.shared.log(category: .general, message: "SettingsMigrationManager.migrateSettings returned nil")
                qrCodeErrorMessage = String(localized: "Failed to decode or migrate settings from QR code")
                return
            }

            LogManager.shared.log(category: .general, message: "QR code decoded successfully. Components: nightscout=\(settings.nightscout != nil), remote=\(settings.remote != nil), alarms=\(settings.alarms != nil), apns=\(settings.apns != nil)")

            // Check version compatibility
            let currentVersion = AppVersionManager().version()
            if !SettingsMigrationManager.isCompatibleVersion(settings.appVersion) {
                qrCodeErrorMessage = SettingsMigrationManager.getCompatibilityMessage(for: settings.appVersion)
                // Still try to apply settings, but warn user
            }

            // Store settings and create preview for confirmation
            pendingImportSettings = settings
            pendingImportSource = String(localized: "QR code")
            createImportPreview(from: settings)

        } catch {
            let currentVersion = AppVersionManager().version()
            qrCodeErrorMessage = String(localized: "Import failed. This might be due to a version change (current: \(currentVersion)). Please try exporting settings from the source device again.")
            LogManager.shared.log(category: .general, message: "QR code import failed: \(error.localizedDescription)")
        }
    }

    private func applyImportedSettings(_ settings: CombinedSettingsExport, source: String) throws {
        var importedComponents: [String] = []

        // Apply settings based on what's available
        if let nightscout = settings.nightscout {
            // Check if Nightscout settings are already configured
            let currentNightscout = NightscoutSettingsExport.fromCurrentStorage()
            if currentNightscout.hasValidSettings() {
                // Nightscout is already configured, warn user about overwrite
                LogManager.shared.log(category: .general, message: "Warning: Nightscout settings are already configured. Import will overwrite existing Nightscout settings.")
            }

            nightscout.applyToStorage()
            importedComponents.append(String(localized: "Nightscout settings"))
            LogManager.shared.log(category: .general, message: "Nightscout settings imported from \(source) (version: \(nightscout.version))")
        }

        if let dexcom = settings.dexcom {
            // Check if Dexcom settings are already configured
            let currentDexcom = DexcomSettingsExport.fromCurrentStorage()
            if currentDexcom.hasValidSettings() {
                LogManager.shared.log(category: .general, message: "Warning: Dexcom settings are already configured. Import will overwrite existing Dexcom settings.")
            }

            dexcom.applyToStorage()
            importedComponents.append(String(localized: "Dexcom settings"))
            LogManager.shared.log(category: .general, message: "Dexcom settings imported from \(source) (version: \(dexcom.version))")
        }

        if let remote = settings.remote {
            if remote.hasValidSettings() {
                let validation = remote.validateCompatibilityWithCurrentStorage()
                if validation.isCompatible {
                    remote.applyToStorage()
                    importedComponents.append(String(localized: "Remote settings (\(remote.remoteType.displayName))"))
                    LogManager.shared.log(category: .general, message: "Remote settings imported from \(source) (version: \(remote.version), type: \(remote.remoteType.rawValue), device: \(remote.device))")
                } else {
                    throw NSError(domain: "SettingsImport", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Remote settings conflict: \(validation.message)")])
                }
            } else {
                throw NSError(domain: "SettingsImport", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Invalid remote settings in \(source)")])
            }
        }

        if let alarms = settings.alarms {
            LogManager.shared.log(category: .general, message: "Attempting to import alarm settings: \(alarms.alarms.count) alarms")
            alarms.applyToStorage()
            importedComponents.append(String(localized: "Alarm settings (\(alarms.alarms.count) alarms)"))
            LogManager.shared.log(category: .general, message: "Alarm settings imported from \(source) (version: \(alarms.version), \(alarms.alarms.count) alarms)")
        }

        if let apns = settings.apns {
            if apns.hasValidSettings() {
                apns.applyToStorage()
                importedComponents.append(String(localized: "APNS settings"))
                LogManager.shared.log(category: .general, message: "APNS settings imported from \(source) (version: \(apns.version), keyId: \(apns.keyId))")
            } else {
                throw NSError(domain: "SettingsImport", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Invalid APNS settings in \(source)")])
            }
        }

        // Update the success message with what was imported
        if !importedComponents.isEmpty {
            let componentsList = importedComponents.joined(separator: ", ")
            qrCodeErrorMessage = String(localized: "Successfully imported: \(componentsList)")
            qrCodeMessageIsSuccess = true
        }
    }

    func generateQRCodeForExport() -> String? {
        let settings: CombinedSettingsExport?

        switch exportType {
        case .nightscout:
            let nightscoutSettings = NightscoutSettingsExport.fromCurrentStorage()
            if !nightscoutSettings.hasValidSettings() {
                qrCodeErrorMessage = String(localized: "Please configure your Nightscout settings first (URL and Token)")
                return nil
            }
            settings = CombinedSettingsExport(
                nightscout: nightscoutSettings,
                exportType: exportType.rawValue
            )
        case .remote:
            let remoteSettings = RemoteSettingsExport.fromCurrentStorage()
            if !remoteSettings.hasValidSettings() {
                let currentRemoteType = Storage.shared.remoteType.value
                if currentRemoteType == .none {
                    qrCodeErrorMessage = String(localized: "Please configure your Remote settings first (select a remote type and configure required fields)")
                } else {
                    qrCodeErrorMessage = String(localized: "Please complete your Remote settings configuration (check required fields for \(currentRemoteType.displayName))")
                }
                return nil
            }
            settings = CombinedSettingsExport(
                remote: remoteSettings,
                exportType: exportType.rawValue
            )
        case .alarms:
            let alarmSettings = AlarmSettingsExport.fromCurrentStorage()
            LogManager.shared.log(category: .general, message: "Generating alarm export: \(alarmSettings.alarms.count) alarms")
            if !alarmSettings.hasValidSettings() {
                qrCodeErrorMessage = String(localized: "Please configure your Alarm settings first")
                return nil
            }
            settings = CombinedSettingsExport(
                alarms: alarmSettings,
                exportType: exportType.rawValue
            )
        case .dexcom:
            let dexcomSettings = DexcomSettingsExport.fromCurrentStorage()
            if !dexcomSettings.hasValidSettings() {
                qrCodeErrorMessage = String(localized: "Please configure your Dexcom Share settings first (username and password)")
                return nil
            }
            settings = CombinedSettingsExport(
                dexcom: dexcomSettings,
                exportType: exportType.rawValue
            )
        case .apns:
            let apnsSettings = APNSSettingsExport.fromCurrentStorage()
            if !apnsSettings.hasValidSettings() {
                qrCodeErrorMessage = String(localized: "Please configure your APNS settings first (valid APNS Key ID and APNS Key)")
                return nil
            }
            settings = CombinedSettingsExport(
                apns: apnsSettings,
                exportType: exportType.rawValue
            )
        }

        return settings?.encodeToJSON()
    }

    func showAlarmSelection() {
        exportType = .alarms
        isShowingAlarmSelection = true
    }

    func exportSelectedAlarms(_ selectedAlarms: [Alarm]) {
        let settings = AlarmSettingsExport.fromSelectedAlarms(selectedAlarms)
        if let qrString = settings.encodeToJSON() {
            qrCodeString = qrString
            isShowingQRCodeDisplay = true

            // Track which alarms were exported
            let exportedIds = Set(selectedAlarms.map { $0.id })
            exportedAlarmIds.formUnion(exportedIds)
        }
        isShowingAlarmSelection = false
    }

    func cancelAlarmSelection() {
        isShowingAlarmSelection = false
    }

    func resetExportedAlarms() {
        exportedAlarmIds.removeAll()
    }

    private func createImportPreview(from settings: CombinedSettingsExport) {
        let nightscoutURL = settings.nightscout?.url.isEmpty == false ? settings.nightscout?.url : nil
        let dexcomUsername = settings.dexcom?.userName.isEmpty == false ? settings.dexcom?.userName : nil
        let remoteType = settings.remote?.remoteType != .none ? settings.remote?.remoteType.rawValue : nil
        let alarmCount = settings.alarms?.alarms.count ?? 0
        let alarmNames = settings.alarms?.alarms.map { $0.name } ?? []
        let apnsKeyId = settings.apns?.keyId.isEmpty == false ? settings.apns?.keyId : nil

        // Check if any settings are actually present
        let hasAnySettings = (nightscoutURL != nil && !nightscoutURL!.isEmpty) ||
            (dexcomUsername != nil && !dexcomUsername!.isEmpty) ||
            (remoteType != nil && !remoteType!.isEmpty && remoteType != "None") ||
            alarmCount > 0 ||
            (apnsKeyId != nil && !apnsKeyId!.isEmpty)

        LogManager.shared.log(category: .general, message: "Import preview check - nightscoutURL: \(nightscoutURL.map { LogRedactor.url($0) } ?? "nil"), dexcomUsername: \(dexcomUsername.map { LogRedactor.username($0) } ?? "nil"), remoteType: \(remoteType ?? "nil"), alarmCount: \(alarmCount), apnsKeyIdPresent: \(apnsKeyId != nil), hasAnySettings: \(hasAnySettings)")

        if hasAnySettings {
            LogManager.shared.log(category: .general, message: "Creating import preview with settings")
            importPreview = ImportPreview(
                nightscoutURL: nightscoutURL,
                dexcomUsername: dexcomUsername,
                remoteType: remoteType,
                alarmCount: alarmCount,
                alarmNames: alarmNames,
                apnsKeyId: apnsKeyId
            )
            LogManager.shared.log(category: .general, message: "Created importPreview - nightscoutURL: \(importPreview?.nightscoutURL.map { LogRedactor.url($0) } ?? "nil"), remoteType: \(importPreview?.remoteType ?? "nil"), alarmCount: \(importPreview?.alarmCount ?? 0)")
            showImportConfirmation = true
            LogManager.shared.log(category: .general, message: "Set showImportConfirmation = true")
        } else {
            LogManager.shared.log(category: .general, message: "No settings found, clearing import data")
            // No settings found, show alert and clear any pending data
            importNotFoundMessage = String(localized: "The settings file exists but contains no valid settings to import.")
            showImportNotFoundAlert = true
            showImportConfirmation = false
            importPreview = nil
            pendingImportSettings = nil
            pendingImportSource = ""
            LogManager.shared.log(category: .general, message: "Set showImportConfirmation = false")
        }
    }

    func confirmImport() {
        guard let settings = pendingImportSettings else { return }

        do {
            try applyImportedSettings(settings, source: pendingImportSource)
        } catch {
            qrCodeErrorMessage = String(localized: "Import failed: \(error.localizedDescription)")
        }

        // Reset confirmation state
        showImportConfirmation = false
        importPreview = nil
        pendingImportSettings = nil
        pendingImportSource = ""
    }

    func cancelImport() {
        showImportConfirmation = false
        importPreview = nil
        pendingImportSettings = nil
        pendingImportSource = ""
    }
}
