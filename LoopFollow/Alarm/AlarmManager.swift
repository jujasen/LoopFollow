// LoopFollow
// AlarmManager.swift

import Foundation
import UserNotifications

class AlarmManager {
    static let shared = AlarmManager()

    private let evaluators: [AlarmType: AlarmCondition]
    private var lastBGAlarmTime: Date?

    private init(
        conditionTypes: [AlarmCondition.Type] = [
            BuildExpireCondition.self,
            LowBGCondition.self,
            HighBGCondition.self,
            FastDropCondition.self,
            NotLoopingCondition.self,
            OverrideStartCondition.self,
            OverrideEndCondition.self,
            TempTargetStartCondition.self,
            TempTargetEndCondition.self,
            RecBolusCondition.self,
            COBCondition.self,
            MissedReadingCondition.self,
            FastRiseCondition.self,
            TemporaryCondition.self,
            SensorAgeCondition.self,
            PumpChangeCondition.self,
            PumpVolumeCondition.self,
            PumpBatteryCondition.self,
            IOBCondition.self,
            BatteryCondition.self,
            BatteryDropCondition.self,
            FutureCarbsCondition.self,
            DBSizeCondition.self,
            PumpFailureCondition.self,
            EveningWatchCondition.self,
        ]
    ) {
        var dict = [AlarmType: AlarmCondition]()
        conditionTypes.forEach { dict[$0.type] = $0.init() }
        evaluators = dict
    }

    func checkAlarms(data: AlarmData) {
        let now = Date()
        var alarmTriggered = false

        // No alarm activity while onboarding is on screen — existing or
        // QR-imported alarms shouldn't sound mid-setup.
        if Observable.shared.isOnboardingActive.value {
            if Observable.shared.currentAlarm.value != nil {
                stopAlarm()
            }
            return
        }

        let config = Storage.shared.alarmConfiguration.value

        // Honor the "Snooze All" setting. If active, stop any current alarm and exit.
        if let snoozeUntil = config.snoozeUntil, snoozeUntil > now {
            if Observable.shared.currentAlarm.value != nil {
                stopAlarm()
            }
            return
        }

        let alarms = Storage.shared.alarms.value

        let sorted = alarms.sorted(by: Alarm.byPriorityThenSpec)
        var skipType: AlarmType?

        let isLatestReadingRecent: Bool = {
            guard let last = data.bgReadings.last else { return false }
            return now.timeIntervalSince(last.date) <= 5 * 60
        }()

        for alarm in sorted {
            // If there is already an active (snoozed) alarm of this type, skip to next [type]
            if alarm.type == skipType {
                continue
            }

            // If an alarm is BG-based, it usually requires recent data.
            // We make a specific exception for .missedReading, whose entire
            // purpose is to fire when recent BG data is NOT recent.
            if alarm.type.isBGBased, alarm.type != .missedReading, !isLatestReadingRecent {
                continue
            }

            // If this is a bg-based alarm and we've already handled that same BG reading,
            // skip until we see a newer one.
            if alarm.type.isBGBased,
               let lastHandled = lastBGAlarmTime,
               let latestDate = data.bgReadings.last?.date,
               !(latestDate > lastHandled)
            {
                continue
            }

            // If the alarm itself is snoozed skip it, and skip lower‑priority alarms of the same type.
            // We still want other types af alarm to go off, so we continue here without breaking
            if let until = alarm.snoozedUntil, until > now {
                skipType = alarm.type
                continue
            }

            // Evaluate the alarm condition.
            guard let checker = evaluators[alarm.type],
                  checker
                  .shouldFire(
                      alarm: alarm,
                      data: data,
                      now: now,
                      config: Storage.shared.alarmConfiguration.value
                  )
            else {
                // If this alarm is active, but no longer fulfill the requirements, stop it.
                // Continue evaluating other alarams
                if Observable.shared.currentAlarm.value == alarm.id {
                    LogManager.shared.log(category: .alarm, message: "Stopping alarm \(alarm) because it no longer meets its requirements", isDebug: true)

                    stopAlarm()
                }

                continue
            }

            // If this alarm is active, and still fulfill the requirements, let it be active
            // Break the loop, nothing else to do
            if Observable.shared.currentAlarm.value == alarm.id {
                break
            }

            // Fire the alarm and break the loop; we only allow one alarm per evaluation tick.
            Observable.shared.currentAlarm.value = alarm.id

            alarm.trigger(config: Storage.shared.alarmConfiguration.value, now: now)

            // Store the latest bg time so we don't use it again
            if alarm.type.isBGBased,
               let latestDate = data.bgReadings.last?.date
            {
                lastBGAlarmTime = latestDate
            }

            if alarm.type == .temporary {
                // turn it off and persist
                var list = Storage.shared.alarms.value
                if let idx = list.firstIndex(where: { $0.id == alarm.id }) {
                    list[idx].isEnabled = false
                    list[idx].snoozedUntil = nil
                    Storage.shared.alarms.value = list
                }
            }

            alarmTriggered = true
            break
        }

        if isLatestReadingRecent, Storage.shared.persistentNotification.value, !alarmTriggered, let latestDate = data.bgReadings.last?.date, latestDate > Storage.shared.persistentNotificationLastBGTime.value {
            sendNotification(title: "Latest BG")
            Storage.shared.persistentNotificationLastBGTime.value = now
        }
    }

    func performSnooze(_ snoozeUnits: Int? = nil) {
        guard let alarmID = Observable.shared.currentAlarm.value else { return }
        var alarms = Storage.shared.alarms.value
        if let idx = alarms.firstIndex(where: { $0.id == alarmID }) {
            let alarm = alarms[idx]
            let units = snoozeUnits ?? alarm.snoozeDuration
            if units > 0 {
                let snoozeSeconds = Double(units) * alarm.type.snoozeTimeUnit.seconds
                alarms[idx].snoozedUntil = Date().addingTimeInterval(snoozeSeconds)
                Storage.shared.alarms.value = alarms
            }
            Observable.shared.alarmSoundPlaying.value = false
            stopAlarm()
        }
    }

    // MARK: - Pump-delivery alert

    /// «Jeg har sjekket»: silent until the condition clears or the pod is changed.
    func acknowledgePumpFailure(now: Date = Date()) {
        let pod = Storage.shared.cageInsertTime.value
        Storage.shared.pumpFailureAcknowledgement.value = PumpFailureAcknowledgement(
            acknowledgedAt: now,
            podInsertTime: pod > 0 ? pod : nil
        )
        LogManager.shared.log(category: .alarm, message: "Pump delivery alert acknowledged")
        stopPumpFailureAlarm()
    }

    /// «Slumre 1 t».
    func snoozePumpFailure(for interval: TimeInterval = 3600, now: Date = Date()) {
        var alarms = Storage.shared.alarms.value
        for idx in alarms.indices where alarms[idx].type == .pumpFailure {
            alarms[idx].snoozedUntil = now.addingTimeInterval(interval)
        }
        Storage.shared.alarms.value = alarms
        LogManager.shared.log(category: .alarm, message: "Pump delivery alert snoozed for \(Int(interval / 60)) min")
        stopPumpFailureAlarm()
    }

    private func stopPumpFailureAlarm() {
        // Works also when the app was relaunched from the notification and no alarm is
        // active in memory yet.
        if let id = Observable.shared.currentAlarm.value,
           Storage.shared.alarms.value.first(where: { $0.id == id })?.type != .pumpFailure
        {
            return
        }
        Observable.shared.alarmSoundPlaying.value = false
        stopAlarm()
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.categoryIdentifier == Self.pumpFailureCategory }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Evening watch

    /// «Se over»: the bolus screen filled in with the suggestion; the alarm is quiet meanwhile.
    func reviewEveningWatch(now: Date = Date()) {
        guard let open = AIBolusSuggestionStore.shared.openEveningWatch(now: now) else { return }
        snoozeEveningWatch(until: now.addingTimeInterval(20 * 60))
        AIBolusSuggestionStore.shared.review(id: open.id)
        LogManager.shared.log(category: .alarm, message: "Evening watch: reviewing \(open.units) U")
    }

    /// Sent from the bolus screen: quiet until Loop has the bolus and closes the suggestion.
    func eveningWatchSent(now: Date = Date()) {
        snoozeEveningWatch(until: now.addingTimeInterval(60 * 60))
    }

    /// «Ikke nå»: the alarm is quiet for 30 minutes; the suggestion stays on the main screen.
    func quietEveningWatch(now: Date = Date()) {
        snoozeEveningWatch(until: now.addingTimeInterval(30 * 60))
    }

    /// «Avslå»: declined here and, through Nightscout, in Loop.
    func declineEveningWatch(now: Date = Date()) {
        for suggestion in AIBolusSuggestionStore.shared.visible(now: now) where suggestion.isEveningWatch {
            AIBolusSuggestionStore.shared.dismiss(suggestion, at: now)
        }
        LogManager.shared.log(category: .alarm, message: "Evening watch suggestion declined")
        snoozeEveningWatch(until: now.addingTimeInterval(60))
    }

    private func snoozeEveningWatch(until: Date) {
        var alarms = Storage.shared.alarms.value
        for idx in alarms.indices where alarms[idx].type == .eveningWatch {
            alarms[idx].snoozedUntil = until
        }
        Storage.shared.alarms.value = alarms
        // Also when the app was opened from the notification and no alarm is active in memory yet.
        if let id = Observable.shared.currentAlarm.value,
           alarms.first(where: { $0.id == id })?.type != .eveningWatch
        {
            return
        }
        Observable.shared.alarmSoundPlaying.value = false
        stopAlarm()
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.categoryIdentifier == Self.eveningWatchCategory }
                .map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Notifications

    static let alarmCategory = "category"
    static let pumpFailureCategory = "pumpFailure"
    static let snoozeAction = "snooze"
    static let pumpFailureAcknowledgeAction = "pumpFailure.acknowledge"
    static let pumpFailureSnoozeAction = "pumpFailure.snooze1h"
    static let eveningWatchCategory = "eveningWatch"
    static let eveningWatchReviewAction = "eveningWatch.review"
    static let eveningWatchNotNowAction = "eveningWatch.notNow"

    /// Every category the app posts with. Setting categories replaces all of them,
    /// so they are always registered together.
    static func registerNotificationCategories(snoozeTitle: String = String(localized: "Snooze")) {
        let openApp = UNNotificationAction(identifier: "OPEN_APP_ACTION", title: String(localized: "Open App"), options: .foreground)
        let background = UNNotificationCategory(identifier: BackgroundAlertIdentifier.categoryIdentifier, actions: [openApp], intentIdentifiers: [], options: [])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: snoozeTitle, options: [])
        let alarm = UNNotificationCategory(identifier: alarmCategory, actions: [snooze], intentIdentifiers: [], options: [])
        let acknowledge = UNNotificationAction(identifier: pumpFailureAcknowledgeAction, title: PumpFailureText.acknowledgeTitle, options: [])
        let snoozeHour = UNNotificationAction(identifier: pumpFailureSnoozeAction, title: PumpFailureText.snoozeHourTitle, options: [])
        let pumpFailure = UNNotificationCategory(identifier: pumpFailureCategory, actions: [acknowledge, snoozeHour], intentIdentifiers: [], options: [])
        let review = UNNotificationAction(identifier: eveningWatchReviewAction, title: EveningWatchText.review, options: .foreground)
        let notNow = UNNotificationAction(identifier: eveningWatchNotNowAction, title: EveningWatchText.notNow, options: [])
        let eveningWatch = UNNotificationCategory(identifier: eveningWatchCategory, actions: [review, notNow], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([background, alarm, pumpFailure, eveningWatch])
    }

    /// Handles a tap on a notification action; true when it was an alarm action.
    @discardableResult
    func handleNotificationAction(_ identifier: String) -> Bool {
        switch identifier {
        case Self.snoozeAction:
            performSnooze()
        case Self.pumpFailureAcknowledgeAction:
            acknowledgePumpFailure()
        case Self.pumpFailureSnoozeAction:
            snoozePumpFailure()
        case Self.eveningWatchNotNowAction:
            quietEveningWatch()
        default:
            return false
        }
        return true
    }

    func stopAlarm() {
        AlarmSound.stop()
        Observable.shared.currentAlarm.value = nil
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func sendNotification(title: String, body: String? = nil, actionTitle: String? = nil, category: String = AlarmManager.alarmCategory, silent: Bool = false) {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        if let actionTitle = actionTitle {
            Self.registerNotificationCategories(snoozeTitle: actionTitle)
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle += Observable.shared.bgText.value + " "
        content.subtitle += Observable.shared.directionText.value + " "
        content.subtitle += Observable.shared.deltaText.value
        if let body { content.body = body }
        content.categoryIdentifier = category
        content.sound = silent ? nil : .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
