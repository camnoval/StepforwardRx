//
//  StepforwardRxApp.swift
//  StepforwardRx
//
//  Created by Noval, Cameron on 1/17/26.
//

import SwiftUI
import HealthKit

@main
struct StepForwardRxApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - HealthKit Manager
class HealthKitManager: ObservableObject, @unchecked Sendable{
    let healthStore = HKHealthStore()
    @Published var isAuthorized = false
    @Published var uploadStatus = "Not configured"
    @Published var uploadProgress: Double = 0.0
    
    // The 5 mobility metrics we're tracking
    let metricsToTrack: [HKQuantityTypeIdentifier] = [
        .walkingDoubleSupportPercentage,
        .walkingAsymmetryPercentage,
        .walkingSpeed,
        .walkingStepLength,
        .appleWalkingSteadiness
    ]
    
    // Request HealthKit permissions
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
        
        // Enable background delivery for each metric
        for identifier in metricsToTrack {
            if let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) {
                try? await healthStore.enableBackgroundDelivery(for: quantityType, frequency: .daily)
            }
        }
    }
    
    // Query historical data (up to 2 years back)
    func queryHistoricalData(participantID: String) async throws {
        print("🚀 Starting historical data query...")
        
        // First ensure participant exists before we start batching
        try await ensureParticipantExists(participantID: participantID)
        
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .year, value: -2, to: endDate) ?? endDate
        
        // Get all dates in range
        var currentDate = startDate
        var allDates: [Date] = []
        
        while currentDate <= endDate {
            allDates.append(currentDate)
            currentDate = Calendar.current.date(byAdding: .day, value: 1, to: currentDate) ?? endDate
        }
        
        print("📅 Will query \(allDates.count) days of data")
        
        let totalDays = allDates.count
        var batch: [[String: Any]] = []
        let batchSize = 50  // Upload 50 days at a time
        
        // Query each day
        for (index, date) in allDates.enumerated() {
            let progress = Double(index) / Double(totalDays)
            
            if index % 10 == 0 {
                await MainActor.run {
                    self.uploadStatus = "Processing day \(index + 1) of \(totalDays)..."
                    self.uploadProgress = progress
                }
            }
            
            let dayData = try await queryDayData(for: date)
            
            // Build batch payload - ALWAYS include all keys
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            
            var payload: [String: Any] = [
                "participant_id": participantID,
                "date": dateFormatter.string(from: date),
                "double_support_time": dayData["double_support_time"] as Any? ?? NSNull(),
                "walking_asymmetry": dayData["walking_asymmetry"] as Any? ?? NSNull(),
                "walking_speed": dayData["walking_speed"] as Any? ?? NSNull(),
                "walking_step_length": dayData["walking_step_length"] as Any? ?? NSNull(),
                "walking_steadiness": dayData["walking_steadiness"] as Any? ?? NSNull()
            ]
            
            batch.append(payload)
            
            // Upload when batch is full or at the end
            if batch.count >= batchSize || index == allDates.count - 1 {
                try await uploadBatch(batch: batch)
                batch = []
            }
        }
        
        print("✅ Historical data query complete!")
        
        await MainActor.run {
            self.uploadStatus = "Upload complete!"
            self.uploadProgress = 1.0
        }
    }
    
    // Batch upload function
    func uploadBatch(batch: [[String: Any]]) async throws {
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics") else {
            throw HealthKitError.invalidURL
        }
        
        print("📦 Uploading batch of \(batch.count) records...")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: batch)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            print("❌ Batch upload failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            print("❌ Error response: \(errorBody)")
            throw HealthKitError.uploadFailed
        }
        
        print("✅ Batch uploaded successfully")
    }
    
    // Query data for a specific day
    func queryDayData(for date: Date) async throws -> [String: Double?] {
        print("🔍 Querying data for \(date)")
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date
        
        var results: [String: Double?] = [:]
        
        for identifier in metricsToTrack {
            guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
                print("⚠️ Could not create quantity type for \(identifier)")
                continue
            }
            
            let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: endOfDay, options: .strictStartDate)
            
            do {
                let average = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Double?, Error>) in
                    let query = HKStatisticsQuery(quantityType: quantityType,
                                                 quantitySamplePredicate: predicate,
                                                 options: .discreteAverage) { _, statistics, error in
                        if let error = error {
                            print("❌ Query error for \(identifier): \(error)")
                            continuation.resume(throwing: error)
                            return
                        }
                        
                        // Get the appropriate unit for this metric
                        let unit = self.getUnit(for: identifier)
                        let value = statistics?.averageQuantity()?.doubleValue(for: unit)
                        print("   \(self.getKeyName(for: identifier)): \(value?.description ?? "nil")")
                        continuation.resume(returning: value)
                    }
                    
                    self.healthStore.execute(query)
                }
                
                results[self.getKeyName(for: identifier)] = average
            } catch {
                print("⚠️ Failed to query \(identifier): \(error)")
                results[self.getKeyName(for: identifier)] = nil
            }
        }
        
        return results
    }
    
    // Helper to ensure participant exists - creates it if new, throws error if taken
    func ensureParticipantExists(participantID: String) async throws {
        // First check if participant already exists
        guard let checkUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/participants?id=eq.\(participantID)&select=id") else {
            throw HealthKitError.invalidURL
        }
        
        var checkRequest = URLRequest(url: checkUrl)
        checkRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        checkRequest.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        checkRequest.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        let (checkData, _) = try await URLSession.shared.data(for: checkRequest)
        let existingParticipants = try JSONSerialization.jsonObject(with: checkData) as? [[String: Any]] ?? []
        
        if !existingParticipants.isEmpty {
            // Participant already exists - this is their device, continue
            return
        }
        
        // Participant doesn't exist, try to create
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/participants") else {
            throw HealthKitError.invalidURL
        }
        
        let payload: [String: Any] = ["id": participantID]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HealthKitError.participantTaken
        }
    }
    
    // Upload data to server
    // Upload single day's data (used for daily background updates)
    func uploadData(participantID: String, date: Date, metrics: [String: Double?]) async throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: date)
        
        var payload: [String: Any] = [
            "participant_id": participantID,
            "date": dateString,
            "double_support_time": metrics["double_support_time"] as Any? ?? NSNull(),
            "walking_asymmetry": metrics["walking_asymmetry"] as Any? ?? NSNull(),
            "walking_speed": metrics["walking_speed"] as Any? ?? NSNull(),
            "walking_step_length": metrics["walking_step_length"] as Any? ?? NSNull(),
            "walking_steadiness": metrics["walking_steadiness"] as Any? ?? NSNull()
        ]
        
        print("📤 Uploading data for \(dateString)")
        
        // First ensure participant exists
        try await ensureParticipantExists(participantID: participantID)
        
        // Check if data already exists for this date
        guard let checkUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(participantID)&date=eq.\(dateString)") else {
            throw HealthKitError.invalidURL
        }
        
        var checkRequest = URLRequest(url: checkUrl)
        checkRequest.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        checkRequest.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        
        let (checkData, _) = try await URLSession.shared.data(for: checkRequest)
        let existingRows = try JSONSerialization.jsonObject(with: checkData) as? [[String: Any]] ?? []
        
        guard let url = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics?participant_id=eq.\(participantID)&date=eq.\(dateString)") else {
            throw HealthKitError.invalidURL
        }
        
        var request = URLRequest(url: url)
        
        if existingRows.isEmpty {
            // INSERT new row
            request.httpMethod = "POST"
            request.setValue("https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics", forHTTPHeaderField: "URL")
            guard let insertUrl = URL(string: "https://tcagznodtcvlnhharmgj.supabase.co/rest/v1/gait_metrics") else {
                throw HealthKitError.invalidURL
            }
            request = URLRequest(url: insertUrl)
            request.httpMethod = "POST"
        } else {
            // UPDATE existing row
            request.httpMethod = "PATCH"
        }
        
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRjYWd6bm9kdGN2bG5oaGFybWdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg2NzUzODcsImV4cCI6MjA4NDI1MTM4N30.ki4vUdHmfW81E0F20uvcgH9oU3M7AcYwp0fD1s3gVfU", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            print("❌ Upload failed with status: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw HealthKitError.uploadFailed
        }
        
        print("✅ Upload successful (row \(existingRows.isEmpty ? "inserted" : "updated"))")
    }
    
    // Setup background observer for daily updates
    func setupBackgroundObserver(participantID: String) {
        // Use a single observer for walking speed as the trigger
        // (all metrics update together anyway)
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: .walkingSpeed) else {
            return
        }
        
        let query = HKObserverQuery(sampleType: quantityType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            
            print("🔔 Background observer triggered")
            
            // When new data arrives, upload yesterday's data
            Task {
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                if let dayData = try? await self?.queryDayData(for: yesterday) {
                    try? await self?.uploadData(participantID: participantID, date: yesterday, metrics: dayData)
                }
            }
            
            completionHandler()
        }
        
        healthStore.execute(query)
    }
    
    // Helper: Get unit for metric
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
    
    // Helper: Get JSON key name for metric
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
}

// MARK: - Setup View
struct ContentView: View {
    @StateObject private var healthKitManager = HealthKitManager()
    @AppStorage("participantID") private var participantID: String = ""
    @AppStorage("isSetupComplete") private var isSetupComplete: Bool = false
    @State private var isLoading = false

    
    var body: some View {
        NavigationView {
            if isSetupComplete {
                // Setup complete view
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    
                    Text("Setup Complete")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("Your mobility data is being tracked automatically.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    Text("Participant ID: \(participantID)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top)
                    
                    Divider()
                        .padding(.vertical)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What happens next:")
                            .font(.headline)
                        
                        Label("Walk normally throughout your day", systemImage: "figure.walk")
                        Label("Data uploads automatically", systemImage: "icloud.and.arrow.up")
                        Label("You don't need to open this app again", systemImage: "hand.raised.fill")
                        Label("Keep your phone with you while walking", systemImage: "iphone")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(10)
                    
                    // Test button (optional - remove for production)
                    Button("Test Upload (Today's Data)") {
                        Task {
                            let today = Calendar.current.date(byAdding: .day, value: 0, to: Date()) ?? Date()
                            if let dayData = try? await healthKitManager.queryDayData(for: today) {
                                try? await healthKitManager.uploadData(participantID: participantID, date: today, metrics: dayData)
                                print("✅ Test upload completed")
                            }
                        }
                    }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    Button("Reset Setup") {
                        isSetupComplete = false
                        participantID = ""
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
                .padding()
            } else {
                // Setup flow
                VStack(spacing: 30) {
                    VStack(spacing: 10) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("StepForward Rx")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Mobility Monitoring Study")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Setup Instructions:")
                            .font(.headline)
                        
                        Label("Enter your participant ID", systemImage: "number.circle")
                        Label("Grant Health app access", systemImage: "heart.circle")
                        Label("Historical data will upload", systemImage: "arrow.up.circle")
                        Label("Daily updates happen automatically", systemImage: "clock.circle")
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    
                    TextField("Participant ID (e.g., P001)", text: $participantID)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    
                    if isLoading {
                        VStack(spacing: 20) {
                            ProgressView(value: healthKitManager.uploadProgress)
                                .progressViewStyle(.linear)
                                .padding(.horizontal, 40)
                            
                            Text(healthKitManager.uploadStatus)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            
                            Text("You can close the app - upload will continue in background")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    } else {
                        Button(action: {
                            Task {
                                await setupApp()
                            }
                        }) {
                            Text("Begin Setup")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(participantID.isEmpty ? Color.gray : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(participantID.isEmpty)
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                }
                .padding()
            }
        }
    }
    
    func setupApp() async {
        isLoading = true
        
        do {
            // Request HealthKit authorization
            try await healthKitManager.requestAuthorization()
            
            // Upload historical data
            try await healthKitManager.queryHistoricalData(participantID: participantID)
            
            // Setup background observer for daily updates
            healthKitManager.setupBackgroundObserver(participantID: participantID)
            
            // Mark setup as complete
            await MainActor.run {
                isSetupComplete = true
                isLoading = false
            }
        } catch HealthKitError.participantTaken {
            await MainActor.run {
                healthKitManager.uploadStatus = "This participant ID is already taken. Please use a different ID."
                isLoading = false
            }
        } catch {
            await MainActor.run {
                healthKitManager.uploadStatus = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

#Preview {
    ContentView()
}
