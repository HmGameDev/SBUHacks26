import SwiftUI

/// Every cue the arbiter considered: what it said or felt, why, and what it suppressed.
struct CueLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let feedback = model.feedback
        let _ = feedback.logVersion // refresh when the log changes
        List {
            Section("Fire a cue by hand") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(CuePhrases.shared.active, id: \.id) { phrase in
                            Button(phrase.id) { feedback.test(phrase.id) }
                                .buttonStyle(.bordered)
                                .font(.caption)
                        }
                    }
                }
                if !feedback.missingClips.isEmpty {
                    Text("\(feedback.missingClips.count) clips not generated yet; those cues use on-device speech. Run tools/generate_cues.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Log, newest first") {
                ForEach(feedback.log.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.tier.description).bold()
                            Text(entry.outcome)
                                .foregroundStyle(entry.outcome == "spoken" ? Color.green : Color.secondary)
                            Spacer()
                            if let latency = entry.latencyMs {
                                Text(String(format: "%.0f ms", latency)).monospacedDigit()
                            }
                        }
                        .font(.caption)
                        Text(entry.text)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
