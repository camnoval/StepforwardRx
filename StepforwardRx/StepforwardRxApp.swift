//
//  StepforwardRxApp.swift
//  StepforwardRx
//
//  Created by Noval, Cameron on 1/17/26.
//

import SwiftUI
import HealthKit
import BackgroundTasks
import UserNotifications

@main
struct StepForwardRxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    setupHealthKitObservers()
                    cacheHealthKitData()
                }
        }
    }
    
    func setupHealthKitObservers() {
        guard UserDefaults.standard.bool(forKey: "isSetupComplete") else { return }
        
        let healthKitManager = HealthKitManager()
        
        // Set up observer queries for each metric
        for identifier in healthKitManager.metricsToTrack {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            
            let query = HKObserverQuery(sampleType: quantityType, predicate: nil) { query, completionHandler, error in
                print("🔔 HealthKit update detected for \(identifier.rawValue)")
                
                // Cache immediately when new data arrives
                Task {
                    await self.cacheHealthKitData()
                    
                    // ALSO try to upload if it's been >1 hour since last upload
                    if let lastUpload = UserDefaults.standard.object(forKey: "lastSuccessfulUpload") as? Date,
                       Date().timeIntervalSince(lastUpload) > 3600 {
                        print("⏰ [OBSERVER] Been >1hr since upload, uploading now...")
                        
                        if let participantID = UserDefaults.standard.string(forKey: "participantID"),
                           !participantID.isEmpty {
                            await self.uploadFromBackgroundHelper(participantID: participantID)
                        }
                    }
                }
                
                completionHandler()
            }
            
            healthKitManager.healthStore.execute(query)
            
            // Also enable background delivery
            Task {
                try? await healthKitManager.healthStore.enableBackgroundDelivery(
                    for: quantityType,
                    frequency: .immediate
                )
            }
        }
    }
    
    func uploadFromBackgroundHelper(participantID: String) async {
        print("📤 [OBSERVER UPLOAD] Starting upload from HealthKit observer...")
        
        let healthKitManager = HealthKitManager()
        var uploadCount = 0
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        
        // Only upload last 3 days to keep it quick (we have ~30 seconds)
        for daysAgo in 0...2 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            
            guard let cachedData = UserDefaults.standard.data(forKey: key),
                  let metrics = try? JSONSerialization.jsonObject(with: cachedData) as? [String: Double] else {
                continue
            }
            
            var dayData: [String: Double?] = [:]
            for (k, v) in metrics {
                dayData[k] = v
            }
            
            do {
                try await healthKitManager.uploadData(participantID: participantID, date: date, metrics: dayData)
                uploadCount += 1
                print("✅ [OBSERVER UPLOAD] Uploaded \(df.string(from: date))")
            } catch {
                print("❌ [OBSERVER UPLOAD] Failed: \(error)")
            }
        }
        
        if uploadCount > 0 {
            UserDefaults.standard.set(Date(), forKey: "lastSuccessfulUpload")
            print("✅ [OBSERVER UPLOAD] Completed: \(uploadCount) days uploaded")
        }
    }
    
    func cacheHealthKitData() {
        guard UserDefaults.standard.bool(forKey: "isSetupComplete") else { return }
        
        Task {
            print("📦 [CACHE] Starting cache operation at \(Date())")
            let healthKitManager = HealthKitManager()
            
            for daysAgo in 0...7 {  // Cache a full week
                let targetDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
                await cacheDataForDate(targetDate, healthKitManager: healthKitManager)
            }
            
            print("📦 [CACHE] Cache operation complete")
        }
    }
    
    func cacheDataForDate(_ date: Date, healthKitManager: HealthKitManager) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateKey = "cached_\(dateFormatter.string(from: date))"
        
        // Try to query HealthKit
        if let dayData = try? await healthKitManager.queryDayData(for: date) {
            var cleanData: [String: Double] = [:]
            var hasAnyData = false
            
            for (key, value) in dayData {
                if let val = value {
                    cleanData[key] = val
                    hasAnyData = true
                }
            }
            
            if hasAnyData {
                if let jsonData = try? JSONSerialization.data(withJSONObject: cleanData) {
                    UserDefaults.standard.set(jsonData, forKey: dateKey)
                    UserDefaults.standard.set(Date(), forKey: "\(dateKey)_timestamp")
                    print("✅ [CACHE] Cached \(dateFormatter.string(from: date)): \(cleanData.keys.joined(separator: ", "))")
                }
            } else {
                print("⚠️ [CACHE] No data available for \(dateFormatter.string(from: date))")
            }
        } else {
            // If query fails (phone locked), keep existing cache
            if UserDefaults.standard.data(forKey: dateKey) != nil {
                print("📌 [CACHE] Query failed for \(dateFormatter.string(from: date)), keeping existing cache")
            } else {
                print("❌ [CACHE] Query failed and no existing cache for \(dateFormatter.string(from: date))")
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            if granted {
                print("✅ Notifications enabled")
            } else {
                print("❌ Notifications denied")
            }
        }
        
        // Register upload task
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.stepforwardrx.dataupload", using: nil) { task in
            self.handleUploadTask(task: task as! BGProcessingTask)
        }
        
        print("✅ App launched at \(Date())")
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("📱 [BACKGROUND] App entering background at \(Date())")
        
        // Cache before background - this is critical!
        Task {
            let healthKitManager = HealthKitManager()
            var cacheCount = 0
            
            for daysAgo in 0...7 {
                let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
                if let dayData = try? await healthKitManager.queryDayData(for: date) {
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd"
                    let key = "cached_\(df.string(from: date))"
                    
                    var cleanData: [String: Double] = [:]
                    var hasData = false
                    for (k, v) in dayData {
                        if let val = v {
                            cleanData[k] = val
                            hasData = true
                        }
                    }
                    
                    if hasData {
                        if let json = try? JSONSerialization.data(withJSONObject: cleanData) {
                            UserDefaults.standard.set(json, forKey: key)
                            UserDefaults.standard.set(Date(), forKey: "\(key)_timestamp")
                            cacheCount += 1
                        }
                    }
                }
            }
            
            print("📱 [BACKGROUND] Cached \(cacheCount) days before background")
        }
        
        scheduleUploadTask()
        print("📱 [BACKGROUND] Scheduled upload task")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("📱 [FOREGROUND] App entering foreground at \(Date())")
        
        // ALWAYS try to upload when app opens
        Task {
            await tryUploadCachedData()
        }
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        print("📱 [ACTIVE] App became active at \(Date())")
        
        // Also try when app becomes active (in case foreground didn't trigger)
        Task {
            // Check if we uploaded recently (within last hour)
            if let lastUpload = UserDefaults.standard.object(forKey: "lastSuccessfulUpload") as? Date,
               Date().timeIntervalSince(lastUpload) < 3600 {
                print("⏭️ [ACTIVE] Skipping upload - uploaded less than 1 hour ago")
                return
            }
            
            await tryUploadCachedData()
        }
    }
    
    func tryUploadCachedData() async {
        guard let participantID = UserDefaults.standard.string(forKey: "participantID"),
              !participantID.isEmpty else {
            print("⚠️ [UPLOAD] No participant ID")
            return
        }
        
        print("📤 [UPLOAD] Starting foreground upload")
        let success = await uploadFromCache(participantID: participantID)
        print(success ? "✅ [UPLOAD] Foreground upload complete" : "⚠️ [UPLOAD] Foreground upload had issues")
    }
    
    func handleUploadTask(task: BGProcessingTask) {
        print("🔄 [BACKGROUND TASK] Upload task started at \(Date())")
        scheduleUploadTask()
        
        task.expirationHandler = {
            print("⚠️ [BACKGROUND TASK] Upload task expired")
            task.setTaskCompleted(success: false)
        }
        
        Task {
            guard let participantID = UserDefaults.standard.string(forKey: "participantID"),
                  !participantID.isEmpty else {
                print("❌ [BACKGROUND TASK] No participant ID")
                task.setTaskCompleted(success: false)
                return
            }
            
            print("📤 [BACKGROUND TASK] Starting background upload")
            let success = await uploadFromCache(participantID: participantID)
            print(success ? "✅ [BACKGROUND TASK] Success" : "⚠️ [BACKGROUND TASK] Failed")
            task.setTaskCompleted(success: success)
        }
    }
    
    func uploadFromCache(participantID: String) async -> Bool {
        print("📤 [UPLOAD] Uploading from CACHE at \(Date())")
        
        let healthKitManager = HealthKitManager()
        var uploadCount = 0
        var skippedCount = 0
        var failedCount = 0
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        
        for daysAgo in 0...7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            let dateStr = df.string(from: date)
            
            guard let cachedData = UserDefaults.standard.data(forKey: key),
                  let metrics = try? JSONSerialization.jsonObject(with: cachedData) as? [String: Double] else {
                print("⚠️ [UPLOAD] No cache for \(dateStr)")
                skippedCount += 1
                continue
            }
            
            // Check cache freshness
            if let cacheTime = UserDefaults.standard.object(forKey: "\(key)_timestamp") as? Date {
                let age = Date().timeIntervalSince(cacheTime)
                print("📦 [UPLOAD] Cache for \(dateStr) is \(Int(age/3600))h old")
                
                if age > 7 * 86400 {  // Older than 7 days
                    print("⚠️ [UPLOAD] Cache too old for \(dateStr), skipping")
                    skippedCount += 1
                    continue
                }
            }
            
            print("📦 [UPLOAD] Found cached data for \(dateStr): \(metrics)")
            
            var dayData: [String: Double?] = [:]
            for (k, v) in metrics {
                dayData[k] = v
            }
            
            do {
                try await healthKitManager.uploadData(participantID: participantID, date: date, metrics: dayData)
                uploadCount += 1
                print("✅ [UPLOAD] Uploaded \(dateStr)")
            } catch {
                failedCount += 1
                print("❌ [UPLOAD] Failed to upload \(dateStr): \(error)")
            }
        }
        
        print("📊 [UPLOAD] Summary: \(uploadCount) uploaded, \(skippedCount) skipped, \(failedCount) failed")
        
        if uploadCount > 0 {
            UserDefaults.standard.set(Date(), forKey: "lastSuccessfulUpload")
            sendNotification(
                title: "✅ Upload Complete",
                body: "Uploaded \(uploadCount) day(s) at \(Date().formatted(date: .omitted, time: .shortened))"
            )
            return true
        } else if skippedCount > 0 {
            sendNotification(
                title: "⚠️ No New Data",
                body: "No cached data available to upload"
            )
            return true
        }
        
        return false
    }
    
    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ [NOTIFICATION] Failed: \(error)")
            } else {
                print("✅ [NOTIFICATION] Sent: \(title)")
            }
        }
    }
}

func scheduleUploadTask() {
    let request = BGProcessingTaskRequest(identifier: "com.stepforwardrx.dataupload")
    
    // Schedule for next 5 PM
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day], from: Date())
    components.hour = 17
    components.minute = 0
    
    var targetDate = calendar.date(from: components) ?? Date()
    if targetDate <= Date() {
        targetDate = calendar.date(byAdding: .day, value: 1, to: targetDate) ?? Date()
    }
    
    request.earliestBeginDate = targetDate
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    
    do {
        try BGTaskScheduler.shared.submit(request)
        print("✅ [SCHEDULE] Upload task scheduled for \(targetDate)")
    } catch {
        print("❌ [SCHEDULE] Failed to schedule: \(error)")
    }
}

// MARK: - HealthKit Manager
class HealthKitManager: ObservableObject, @unchecked Sendable {
    let healthStore = HKHealthStore()
    @Published var isAuthorized = false
    @Published var uploadStatus = "Not configured"
    @Published var uploadProgress: Double = 0.0
    
    let metricsToTrack: [HKQuantityTypeIdentifier] = [
        .walkingDoubleSupportPercentage,
        .walkingAsymmetryPercentage,
        .walkingSpeed,
        .walkingStepLength,
        .appleWalkingSteadiness
    ]
    
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        
        let typesToRead: Set<HKQuantityType> = Set(metricsToTrack.compactMap {
            HKQuantityType.quantityType(forIdentifier: $0)
        })
        
        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
        
        await MainActor.run {
            self.isAuthorized = true
        }
        
        // Enable background delivery with immediate frequency
        for identifier in metricsToTrack {
            if let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) {
                try? await healthStore.enableBackgroundDelivery(for: quantityType, frequency: .immediate)
                print("✅ Enabled background delivery for \(identifier.rawValue)")
            }
        }
    }
    
    func checkParticipantExists(participantID: String) async throws -> Bool {
        // Uppercase the ID since database stores in uppercase
        let uppercaseID = participantID.uppercased()
        
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/participants?id=eq.\(uppercaseID)&select=id") else {
            throw HealthKitError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let existing = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        
        return !existing.isEmpty
    }
    
    func deleteParticipantData(participantID: String) async throws {
        // Delete metrics
        guard let metricsUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(participantID)") else {
            throw HealthKitError.invalidURL
        }
        
        var metricsRequest = URLRequest(url: metricsUrl)
        metricsRequest.httpMethod = "DELETE"
        metricsRequest.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        metricsRequest.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        _ = try await URLSession.shared.data(for: metricsRequest)
        
        // Delete participant
        guard let partUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/participants?id=eq.\(participantID)") else {
            throw HealthKitError.invalidURL
        }
        
        var partRequest = URLRequest(url: partUrl)
        partRequest.httpMethod = "DELETE"
        partRequest.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        partRequest.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        _ = try await URLSession.shared.data(for: partRequest)
    }
    
    func deleteGaitMetrics(participantID: String) async throws {
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(participantID)") else {
            throw HealthKitError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        _ = try await URLSession.shared.data(for: request)
    }
    
    func queryHistoricalData(participantID: String) async throws {
        // IMPORTANT: Uppercase the participant ID since database trigger converts to uppercase
        let uppercaseID = participantID.uppercased()
        
        // Create participant FIRST, before any uploads
        try await ensureParticipantExists(participantID: uppercaseID)
        
        // Now delete old gait metrics
        try await deleteGaitMetrics(participantID: uppercaseID)
        
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .year, value: -2, to: endDate) ?? endDate
        
        var currentDate = startDate
        var allDates: [Date] = []
        
        while currentDate <= endDate {
            allDates.append(currentDate)
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? endDate
        }
        
        let totalDays = allDates.count
        var batch: [[String: Any]] = []
        let batchSize = 50
        
        print("📊 [HISTORICAL] Starting upload of \(totalDays) days for \(uppercaseID)")
        
        for (index, date) in allDates.enumerated() {
            let progress = Double(index) / Double(totalDays)
            
            if index % 10 == 0 {
                await MainActor.run {
                    self.uploadStatus = "Processing day \(index + 1) of \(totalDays)..."
                    self.uploadProgress = progress
                }
            }
            
            let dayData = try await queryDayData(for: date)
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            
            let payload: [String: Any] = [
                "participant_id": uppercaseID,
                "date": df.string(from: date),
                "double_support_time": dayData["double_support_time"] as Any? ?? NSNull(),
                "walking_asymmetry": dayData["walking_asymmetry"] as Any? ?? NSNull(),
                "walking_speed": dayData["walking_speed"] as Any? ?? NSNull(),
                "walking_step_length": dayData["walking_step_length"] as Any? ?? NSNull(),
                "walking_steadiness": dayData["walking_steadiness"] as Any? ?? NSNull()
            ]
            
            batch.append(payload)
            
            if batch.count >= batchSize || index == allDates.count - 1 {
                try await uploadBatch(batch: batch)
                batch = []
            }
        }
        
        await MainActor.run {
            self.uploadStatus = "Upload complete!"
            self.uploadProgress = 1.0
        }
        
        print("✅ [HISTORICAL] Completed upload of \(totalDays) days")
    }
    
    func uploadBatch(batch: [[String: Any]]) async throws {
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics") else {
            throw HealthKitError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: batch)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ [UPLOAD] Invalid response type")
            throw HealthKitError.uploadFailed
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            print("❌ [UPLOAD] HTTP \(httpResponse.statusCode): \(responseBody)")
            throw HealthKitError.uploadFailed
        }
    }
    
    func queryDayData(for date: Date) async throws -> [String: Double?] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date
        
        var results: [String: Double?] = [:]
        
        for identifier in metricsToTrack {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
                continue
            }
            
            let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endOfDay, options: .strictStartDate)
            
            let average = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
                let query = HKStatisticsQuery(quantityType: quantityType,
                                             quantitySamplePredicate: predicate,
                                             options: .discreteAverage) { _, statistics, error in
                    if let error = error {
                        continuation.resume(returning: nil)
                        return
                    }
                    
                    let unit = self.getUnit(for: identifier)
                    let value = statistics?.averageQuantity()?.doubleValue(for: unit)
                    continuation.resume(returning: value)
                }
                
                self.healthStore.execute(query)
            }
            
            results[self.getKeyName(for: identifier)] = average
        }
        
        return results
    }
    
    func ensureParticipantExists(participantID: String) async throws {
        print("🔍 [PARTICIPANT] Checking if participant exists: \(participantID)")
        
        let exists = try await checkParticipantExists(participantID: participantID)
        if exists {
            print("✅ [PARTICIPANT] Participant \(participantID) already exists")
            return
        }
        
        print("📝 [PARTICIPANT] Creating participant: \(participantID)")
        
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/participants") else {
            throw HealthKitError.invalidURL
        }
        
        // Get pharmacy_id from UserDefaults
        let pharmacyID = UserDefaults.standard.string(forKey: "pharmacyID") ?? ""
        
        let payload: [String: Any] = [
            "id": participantID,
            "pharmacy_id": pharmacyID.isEmpty ? NSNull() : pharmacyID
        ]
        
        print("📤 [PARTICIPANT] Payload: \(payload)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("❌ [PARTICIPANT] Invalid response type")
            throw HealthKitError.uploadFailed
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            print("❌ [PARTICIPANT] HTTP \(httpResponse.statusCode): \(responseBody)")
            throw HealthKitError.uploadFailed
        }
        
        print("✅ [PARTICIPANT] Successfully created participant: \(participantID)")
    }
    
    func fetchPharmacies() async throws -> [Pharmacy] {
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/pharmacies?select=*&order=name.asc") else {
            throw HealthKitError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let pharmaciesData = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        
        return pharmaciesData.compactMap { dict in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let address = dict["address"] as? String ?? ""
            return Pharmacy(id: id, name: name, address: address)
        }
    }
    
    func uploadData(participantID: String, date: Date, metrics: [String: Double?]) async throws {
        // Uppercase the ID since database stores in uppercase
        let uppercaseID = participantID.uppercased()
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateString = df.string(from: date)
        
        let payload: [String: Any] = [
            "participant_id": uppercaseID,
            "date": dateString,
            "double_support_time": metrics["double_support_time"] as Any? ?? NSNull(),
            "walking_asymmetry": metrics["walking_asymmetry"] as Any? ?? NSNull(),
            "walking_speed": metrics["walking_speed"] as Any? ?? NSNull(),
            "walking_step_length": metrics["walking_step_length"] as Any? ?? NSNull(),
            "walking_steadiness": metrics["walking_steadiness"] as Any? ?? NSNull()
        ]
        
        try await ensureParticipantExists(participantID: uppercaseID)
        
        // Check if exists
        guard let checkUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(uppercaseID)&date=eq.\(dateString)") else {
            throw HealthKitError.invalidURL
        }
        
        var checkRequest = URLRequest(url: checkUrl)
        checkRequest.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        checkRequest.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        let (checkData, _) = try await URLSession.shared.data(for: checkRequest)
        let existingRows = try JSONSerialization.jsonObject(with: checkData) as? [[String: Any]] ?? []
        
        let url: URL
        let method: String
        
        if existingRows.isEmpty {
            url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics")!
            method = "POST"
        } else {
            url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(uppercaseID)&date=eq.\(dateString)")!
            method = "PATCH"
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HealthKitError.uploadFailed
        }
    }
    
    func reportSideEffect(participantID: String, message: String) async throws {
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/side_effects") else {
            throw HealthKitError.invalidURL
        }
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let payload: [String: Any] = [
            "participant_id": participantID,
            "message": message,
            "reported_at": isoFormatter.string(from: Date())
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HealthKitError.uploadFailed
        }
        
        print("✅ Side effect reported successfully")
    }
    
    private func getUnit(for identifier: HKQuantityTypeIdentifier) -> HKUnit {
        switch identifier {
        case .walkingDoubleSupportPercentage, .walkingAsymmetryPercentage:
            return HKUnit.percent()
        case .walkingSpeed:
            return HKUnit.meter().unitDivided(by: .second())
        case .walkingStepLength:
            return HKUnit.meter()
        case .appleWalkingSteadiness:
            return HKUnit.percent()
        default:
            return HKUnit.count()
        }
    }
    
    private func getKeyName(for identifier: HKQuantityTypeIdentifier) -> String {
        switch identifier {
        case .walkingDoubleSupportPercentage:
            return "double_support_time"
        case .walkingAsymmetryPercentage:
            return "walking_asymmetry"
        case .walkingSpeed:
            return "walking_speed"
        case .walkingStepLength:
            return "walking_step_length"
        case .appleWalkingSteadiness:
            return "walking_steadiness"
        default:
            return identifier.rawValue
        }
    }
}

enum HealthKitError: Error {
    case notAvailable
    case invalidURL
    case uploadFailed
    case participantTaken
    case deleteFailed
}

struct Pharmacy: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let address: String
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var healthKitManager = HealthKitManager()
    @AppStorage("participantID") private var participantID: String = ""
    @AppStorage("pharmacyID") private var pharmacyID: String = ""
    @AppStorage("isSetupComplete") private var isSetupComplete: Bool = false
    @State private var isLoading = false
    @State private var showOverwriteAlert = false
    @State private var pendingParticipantID = ""
    @State private var showReportSheet = false
    @State private var pharmacies: [Pharmacy] = []
    @State private var selectedPharmacy: Pharmacy?
    
    var body: some View {
        if isSetupComplete {
            TabView {
                MainDashboardView(participantID: participantID, healthKitManager: healthKitManager)
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                
                WeeklyDataView(healthKitManager: healthKitManager)
                    .tabItem {
                        Label("My Data", systemImage: "chart.line.uptrend.xyaxis")
                    }
                
                SettingsView(
                    participantID: $participantID,
                    pharmacyID: $pharmacyID,
                    isSetupComplete: $isSetupComplete,
                    healthKitManager: healthKitManager
                )
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        } else {
            SetupView(
                participantID: $participantID,
                pharmacyID: $pharmacyID,
                isSetupComplete: $isSetupComplete,
                healthKitManager: healthKitManager
            )
        }
    }
}

// MARK: - Main Dashboard
struct MainDashboardView: View {
    let participantID: String
    let healthKitManager: HealthKitManager
    @State private var showReportSheet = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 30) {
                    // Status Card
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 70))
                            .foregroundColor(.green)
                        
                        VStack(spacing: 8) {
                            Text("All Set!")
                                .font(.title)
                                .fontWeight(.bold)
                            
                            Text("Participant ID: \(participantID)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 20)
                    
                    // Info Card
                    VStack(alignment: .leading, spacing: 16) {
                        Label("How It Works", systemImage: "info.circle.fill")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            InfoRow(icon: "arrow.clockwise", text: "Data cached continuously")
                            InfoRow(icon: "clock.fill", text: "Auto-upload at 5 PM daily")
                            InfoRow(icon: "arrow.up.circle.fill", text: "Uploads when you open app")
                            InfoRow(icon: "checkmark.circle", text: "No action needed from you")
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(16)
                    .padding(.horizontal)
                    
                    // Last Upload Status
                    if let lastUpload = UserDefaults.standard.object(forKey: "lastSuccessfulUpload") as? Date {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Last Upload")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Text(lastUpload.formatted(date: .abbreviated, time: .shortened))
                                .font(.headline)
                                .foregroundColor(.green)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                    
                    // Report Button
                    Button(action: { showReportSheet = true }) {
                        HStack {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.title3)
                            Text("Report Side Effect or Message")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [Color.orange, Color.orange.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(color: Color.orange.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.horizontal)
                    
                    // Footer Message
                    VStack(spacing: 8) {
                        Text("You're all set!")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("The app will automatically sync your walking data. You can close it anytime.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("StepForward Rx")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showReportSheet) {
                ReportSideEffectView(
                    participantID: participantID,
                    healthKitManager: healthKitManager
                )
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}

// MARK: - Weekly Data View
struct WeeklyDataView: View {
    let healthKitManager: HealthKitManager
    @State private var weekData: [DayMetrics] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if isLoading {
                        ProgressView("Loading your data...")
                            .padding(.top, 50)
                    } else if weekData.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "chart.line.downtrend.xyaxis")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("No data available yet")
                                .font(.headline)
                            Text("Walk around to start collecting data!")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 50)
                    } else {
                        // Walking Speed Chart
                        MetricChartCard(
                            title: "Walking Speed",
                            icon: "figure.walk",
                            data: weekData,
                            valueKeyPath: \.walkingSpeed,
                            unit: "m/s",
                            color: .blue
                        )
                        
                        // Step Length Chart
                        MetricChartCard(
                            title: "Step Length",
                            icon: "ruler",
                            data: weekData,
                            valueKeyPath: \.stepLength,
                            unit: "m",
                            color: .green
                        )
                        
                        // Walking Asymmetry Chart
                        MetricChartCard(
                            title: "Walking Asymmetry",
                            icon: "figure.walk.motion",
                            data: weekData,
                            valueKeyPath: \.asymmetry,
                            unit: "%",
                            color: .orange,
                            multiplier: 100
                        )
                        
                        // Double Support Time Chart
                        MetricChartCard(
                            title: "Double Support Time",
                            icon: "timer",
                            data: weekData,
                            valueKeyPath: \.doubleSupportTime,
                            unit: "%",
                            color: .purple,
                            multiplier: 100
                        )
                    }
                }
                .padding()
            }
            .navigationTitle("My Walking Data")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                loadWeekData()
            }
        }
    }
    
    func loadWeekData() {
        Task {
            isLoading = true
            var data: [DayMetrics] = []
            
            for daysAgo in 0...6 {
                let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
                
                if let dayData = try? await healthKitManager.queryDayData(for: date) {
                    let metrics = DayMetrics(
                        date: date,
                        walkingSpeed: dayData["walking_speed"] ?? nil,
                        stepLength: dayData["walking_step_length"] ?? nil,
                        asymmetry: dayData["walking_asymmetry"] ?? nil,
                        doubleSupportTime: dayData["double_support_time"] ?? nil
                    )
                    data.append(metrics)
                }
            }
            
            await MainActor.run {
                weekData = data.reversed()
                isLoading = false
            }
        }
    }
}

struct DayMetrics: Identifiable {
    let id = UUID()
    let date: Date
    let walkingSpeed: Double?
    let stepLength: Double?
    let asymmetry: Double?
    let doubleSupportTime: Double?
}

struct MetricChartCard: View {
    let title: String
    let icon: String
    let data: [DayMetrics]
    let valueKeyPath: KeyPath<DayMetrics, Double?>
    let unit: String
    let color: Color
    var multiplier: Double = 1.0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title2)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            
            // Simple bar chart
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(data) { day in
                    VStack(spacing: 4) {
                        if let value = day[keyPath: valueKeyPath] {
                            let displayValue = value * multiplier
                            let normalizedHeight = CGFloat(displayValue / maxValue)
                            
                            RoundedRectangle(cornerRadius: 4)
                                .fill(color.opacity(0.8))
                                .frame(width: 35, height: max(normalizedHeight * 120, 10))
                            
                            Text(String(format: "%.1f", displayValue))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 35, height: 10)
                            
                            Text("--")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Text(day.date, format: .dateTime.weekday(.narrow))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            
            HStack {
                Text("Unit: \(unit)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if let avg = averageValue {
                    Text("Avg: \(String(format: "%.1f", avg)) \(unit)")
                        .font(.caption)
                        .foregroundColor(color)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(16)
    }
    
    var maxValue: Double {
        data.compactMap { $0[keyPath: valueKeyPath] }.map { $0 * multiplier }.max() ?? 1.0
    }
    
    var averageValue: Double? {
        let values = data.compactMap { $0[keyPath: valueKeyPath] }.map { $0 * multiplier }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Binding var participantID: String
    @Binding var pharmacyID: String
    @Binding var isSetupComplete: Bool
    let healthKitManager: HealthKitManager
    
    @AppStorage("isDevModeUnlocked") private var isDevModeUnlocked = false
    @State private var showDevLogin = false
    @State private var devUsername = ""
    @State private var devPassword = ""
    @State private var showDevError = false
    
    // Admin credentials (in production, store these securely or on a server)
    private let adminUsername = "admin"
    private let adminPassword = "stepforward2026"
    
    var body: some View {
        NavigationView {
            List {
                Section("Participant Info") {
                    HStack {
                        Text("Participant ID:")
                        Spacer()
                        Text(participantID)
                            .foregroundColor(.secondary)
                    }
                    
                    if let pharmacyName = getPharmacyName() {
                        HStack {
                            Text("Pharmacy:")
                            Spacer()
                            Text(pharmacyName)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Actions") {
                    Button(role: .destructive, action: {
                        isSetupComplete = false
                        participantID = ""
                        pharmacyID = ""
                    }) {
                        Label("Reset App", systemImage: "arrow.counterclockwise")
                    }
                }
                
                Section {
                    if isDevModeUnlocked {
                        NavigationLink(destination: DeveloperSettingsView(healthKitManager: healthKitManager, participantID: participantID)) {
                            Label("Developer Settings", systemImage: "hammer.fill")
                        }
                        
                        Button(role: .destructive, action: {
                            isDevModeUnlocked = false
                        }) {
                            Label("Lock Developer Mode", systemImage: "lock.fill")
                        }
                    } else {
                        Button(action: { showDevLogin = true }) {
                            Label("Developer Settings", systemImage: "lock.fill")
                        }
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Developer settings are password protected")
                }
                
                Section("About") {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showDevLogin) {
                DevLoginView(
                    username: $devUsername,
                    password: $devPassword,
                    isUnlocked: $isDevModeUnlocked,
                    showError: $showDevError,
                    adminUsername: adminUsername,
                    adminPassword: adminPassword
                )
            }
        }
    }
    
    func getPharmacyName() -> String? {
        // This is a simplified version - in production you'd fetch from cache
        guard !pharmacyID.isEmpty else { return nil }
        return pharmacyID
    }
}

// MARK: - Dev Login
struct DevLoginView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var username: String
    @Binding var password: String
    @Binding var isUnlocked: Bool
    @Binding var showError: Bool
    let adminUsername: String
    let adminPassword: String
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("Developer Access")
                    .font(.title)
                    .fontWeight(.bold)
                
                VStack(spacing: 15) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .textContentType(.username)
                    
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                    
                    if showError {
                        Text("Invalid credentials")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                
                Button("Unlock") {
                    if username == adminUsername && password == adminPassword {
                        isUnlocked = true
                        showError = false
                        dismiss()
                    } else {
                        showError = true
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.top, 40)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Developer Settings
struct DeveloperSettingsView: View {
    let healthKitManager: HealthKitManager
    let participantID: String
    
    var body: some View {
        List {
            Section("Cache Management") {
                Button("Show Cache Contents") {
                    showCacheContents()
                }
                
                Button("Clear Cache") {
                    clearCache()
                }
                .foregroundColor(.red)
            }
            
            Section("Testing") {
                Button("Test Upload Now") {
                    Task {
                        await testUpload()
                    }
                }
                
                Button("Test Locked Upload") {
                    Task {
                        await testLockedUpload()
                    }
                }
            }
            
            Section("Debug Info") {
                HStack {
                    Text("Participant ID:")
                    Spacer()
                    Text(participantID)
                        .foregroundColor(.secondary)
                }
                
                if let lastUpload = UserDefaults.standard.object(forKey: "lastSuccessfulUpload") as? Date {
                    HStack {
                        Text("Last Upload:")
                        Spacer()
                        Text(lastUpload.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary)
                    }
                }
                
                HStack {
                    Text("Cached Days:")
                    Spacer()
                    Text("\(countCachedDays())")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Developer Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    func showCacheContents() {
        print("\n📋 ========== CACHE CONTENTS ==========")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        
        for daysAgo in 0...7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            let dateStr = df.string(from: date)
            
            if let cachedData = UserDefaults.standard.data(forKey: key),
               let metrics = try? JSONSerialization.jsonObject(with: cachedData) as? [String: Double] {
                
                if let timestamp = UserDefaults.standard.object(forKey: "\(key)_timestamp") as? Date {
                    let age = Date().timeIntervalSince(timestamp)
                    print("📦 \(dateStr) (cached \(Int(age/3600))h ago):")
                } else {
                    print("📦 \(dateStr) (no timestamp):")
                }
                
                for (metric, value) in metrics.sorted(by: { $0.key < $1.key }) {
                    print("   - \(metric): \(value)")
                }
            } else {
                print("❌ \(dateStr): NO CACHE")
            }
        }
        print("📋 ====================================\n")
    }
    
    func clearCache() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        
        for daysAgo in 0...7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: "\(key)_timestamp")
        }
        
        print("🗑️ Cache cleared")
    }
    
    func testUpload() async {
        print("🧪 [TEST] Manual upload triggered")
        let success = await uploadFromCacheHelper(participantID: participantID, healthKitManager: healthKitManager)
        print(success ? "✅ [TEST] Upload succeeded" : "❌ [TEST] Upload failed")
    }
    
    func testLockedUpload() async {
        print("🔒 [TEST] Simulating locked phone upload")
        let success = await uploadFromCacheHelper(participantID: participantID, healthKitManager: healthKitManager)
        
        if success {
            print("✅ [TEST] Locked phone upload would work!")
        } else {
            print("❌ [TEST] Locked phone upload would fail")
        }
    }
    
    func countCachedDays() -> Int {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        var count = 0
        
        for daysAgo in 0...7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            if UserDefaults.standard.data(forKey: key) != nil {
                count += 1
            }
        }
        
        return count
    }
    
    func uploadFromCacheHelper(participantID: String, healthKitManager: HealthKitManager) async -> Bool {
        print("📤 [UPLOAD] Uploading from CACHE at \(Date())")
        
        var uploadCount = 0
        var skippedCount = 0
        var failedCount = 0
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        
        for daysAgo in 0...7 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            let key = "cached_\(df.string(from: date))"
            let dateStr = df.string(from: date)
            
            guard let cachedData = UserDefaults.standard.data(forKey: key),
                  let metrics = try? JSONSerialization.jsonObject(with: cachedData) as? [String: Double] else {
                print("⚠️ [UPLOAD] No cache for \(dateStr)")
                skippedCount += 1
                continue
            }
            
            if let cacheTime = UserDefaults.standard.object(forKey: "\(key)_timestamp") as? Date {
                let age = Date().timeIntervalSince(cacheTime)
                print("📦 [UPLOAD] Cache for \(dateStr) is \(Int(age/3600))h old")
                
                if age > 7 * 86400 {
                    print("⚠️ [UPLOAD] Cache too old for \(dateStr), skipping")
                    skippedCount += 1
                    continue
                }
            }
            
            print("📦 [UPLOAD] Found cached data for \(dateStr): \(metrics)")
            
            var dayData: [String: Double?] = [:]
            for (k, v) in metrics {
                dayData[k] = v
            }
            
            do {
                try await healthKitManager.uploadData(participantID: participantID, date: date, metrics: dayData)
                uploadCount += 1
                print("✅ [UPLOAD] Uploaded \(dateStr)")
            } catch {
                failedCount += 1
                print("❌ [UPLOAD] Failed to upload \(dateStr): \(error)")
            }
        }
        
        print("📊 [UPLOAD] Summary: \(uploadCount) uploaded, \(skippedCount) skipped, \(failedCount) failed")
        
        if uploadCount > 0 {
            UserDefaults.standard.set(Date(), forKey: "lastSuccessfulUpload")
            return true
        }
        
        return false
    }
}

// MARK: - Setup View
struct SetupView: View {
    @Binding var participantID: String
    @Binding var pharmacyID: String
    @Binding var isSetupComplete: Bool
    let healthKitManager: HealthKitManager
    
    @State private var isLoading = false
    @State private var showOverwriteAlert = false
    @State private var pendingParticipantID = ""
    @State private var pharmacies: [Pharmacy] = []
    @State private var selectedPharmacy: Pharmacy?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("StepForward Rx")
                    .font(.title)
                    .fontWeight(.bold)
                
                TextField("Participant ID", text: $participantID)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                
                // Pharmacy Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Your Pharmacy")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    if pharmacies.isEmpty {
                        ProgressView("Loading pharmacies...")
                            .padding()
                    } else {
                        Picker("Pharmacy", selection: $selectedPharmacy) {
                            Text("Select a pharmacy...").tag(nil as Pharmacy?)
                            ForEach(pharmacies) { pharmacy in
                                VStack(alignment: .leading) {
                                    Text(pharmacy.name)
                                        .font(.subheadline)
                                    Text(pharmacy.address)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .tag(pharmacy as Pharmacy?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .padding(.horizontal)
                    }
                }
                
                if isLoading {
                    VStack {
                        ProgressView(value: healthKitManager.uploadProgress)
                        Text(healthKitManager.uploadStatus)
                            .font(.caption)
                    }
                    .padding()
                } else {
                    Button("Begin Setup") {
                        Task { await checkAndSetup() }
                    }
                    .padding()
                    .background((participantID.isEmpty || selectedPharmacy == nil) ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(participantID.isEmpty || selectedPharmacy == nil)
                }
                
                Spacer()
            }
            .padding()
            .onAppear {
                Task {
                    do {
                        pharmacies = try await healthKitManager.fetchPharmacies()
                    } catch {
                        print("Failed to load pharmacies: \(error)")
                    }
                }
            }
            .alert("Overwrite?", isPresented: $showOverwriteAlert) {
                Button("Cancel", role: .cancel) { pendingParticipantID = "" }
                Button("Overwrite", role: .destructive) {
                    Task { await setupApp(overwrite: true) }
                }
            } message: {
                Text("Participant exists. Overwrite?")
            }
        }
    }
    
    func checkAndSetup() async {
        // Normalize participant ID to lowercase
        pendingParticipantID = participantID.lowercased().trimmingCharacters(in: .whitespaces)
        
        // Save pharmacy selection
        if let pharmacy = selectedPharmacy {
            pharmacyID = pharmacy.id
        }
        
        do {
            let exists = try await healthKitManager.checkParticipantExists(participantID: pendingParticipantID)
            
            if exists {
                await MainActor.run { showOverwriteAlert = true }
            } else {
                await setupApp(overwrite: false)
            }
        } catch {
            print("❌ Error: \(error)")
        }
    }
    
    func setupApp(overwrite: Bool) async {
        isLoading = true
        
        do {
            if overwrite {
                await MainActor.run { healthKitManager.uploadStatus = "Deleting..." }
                try await healthKitManager.deleteParticipantData(participantID: pendingParticipantID)
            }
            
            await MainActor.run { healthKitManager.uploadStatus = "Authorizing..." }
            try await healthKitManager.requestAuthorization()
            
            await MainActor.run { healthKitManager.uploadStatus = "Uploading history..." }
            do {
                try await healthKitManager.queryHistoricalData(participantID: pendingParticipantID)
            } catch {
                print("⚠️ Historical upload warning: \(error)")
                // Continue anyway - historical data upload isn't critical for setup
            }
            
            scheduleUploadTask()
            
            await MainActor.run {
                participantID = pendingParticipantID
                isSetupComplete = true
                isLoading = false
                UserDefaults.standard.set(Date(), forKey: "lastSuccessfulUpload")
            }
            
            // Cache data immediately after setup
            print("📦 [SETUP] Starting initial cache after setup...")
            await cacheHealthKitDataHelper()
            
        } catch {
            await MainActor.run {
                healthKitManager.uploadStatus = "Error: \(error.localizedDescription)"
                isLoading = false
            }
            print("❌ Setup error: \(error)")
        }
    }
    
    func cacheHealthKitDataHelper() async {
        print("📦 [CACHE] Starting cache operation at \(Date())")
        
        for daysAgo in 0...7 {
            let targetDate = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            await cacheDataForDateHelper(targetDate)
        }
        
        print("📦 [CACHE] Cache operation complete")
    }
    
    func cacheDataForDateHelper(_ date: Date) async {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateKey = "cached_\(dateFormatter.string(from: date))"
        
        if let dayData = try? await healthKitManager.queryDayData(for: date) {
            var cleanData: [String: Double] = [:]
            var hasAnyData = false
            
            for (key, value) in dayData {
                if let val = value {
                    cleanData[key] = val
                    hasAnyData = true
                }
            }
            
            if hasAnyData {
                if let jsonData = try? JSONSerialization.data(withJSONObject: cleanData) {
                    UserDefaults.standard.set(jsonData, forKey: dateKey)
                    UserDefaults.standard.set(Date(), forKey: "\(dateKey)_timestamp")
                    print("✅ [CACHE] Cached \(dateFormatter.string(from: date)): \(cleanData.keys.joined(separator: ", "))")
                }
            } else {
                print("⚠️ [CACHE] No data available for \(dateFormatter.string(from: date))")
            }
        } else {
            if UserDefaults.standard.data(forKey: dateKey) != nil {
                print("📌 [CACHE] Query failed for \(dateFormatter.string(from: date)), keeping existing cache")
            } else {
                print("❌ [CACHE] Query failed and no existing cache for \(dateFormatter.string(from: date))")
            }
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - Report Side Effect View
struct ReportSideEffectView: View {
    @Environment(\.dismiss) var dismiss
    let participantID: String
    let healthKitManager: HealthKitManager
    
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Report Side Effect or Message")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.top)
                
                Text("Describe any side effects, symptoms, or messages you want to report to your research team.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                TextEditor(text: $message)
                    .frame(height: 200)
                    .padding(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                Button(action: submitReport) {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Submit Report")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
                .padding(.horizontal)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                
                Button("Cancel") {
                    dismiss()
                }
                .foregroundColor(.red)
                .padding(.bottom)
            }
            .alert("Report Submitted", isPresented: $showSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your report has been submitted successfully at \(Date().formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }
    
    func submitReport() {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        
        isSubmitting = true
        errorMessage = ""
        
        Task {
            do {
                try await healthKitManager.reportSideEffect(participantID: participantID, message: trimmedMessage)
                
                await MainActor.run {
                    isSubmitting = false
                    showSuccess = true
                    message = ""
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "Failed to submit report. Please try again."
                }
            }
        }
    }
}
