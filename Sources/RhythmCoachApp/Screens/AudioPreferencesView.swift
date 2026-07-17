import CoreAudio
import RhythmCore
import SwiftUI

struct AudioPreferencesView: View {
    @Environment(TransportController.self) private var transport

    var body: some View {
        @Bindable var transport = transport
        Form {
            Section("Devices") {
                Picker("Input", selection: $transport.inputDeviceID) {
                    Text("None").tag(AudioDeviceID?.none)
                    ForEach(transport.devices.filter(\.hasInput)) { device in
                        Text("\(device.name) (\(device.inputChannels) in)")
                            .tag(AudioDeviceID?.some(device.id))
                    }
                }
                if transport.inputDevice != nil {
                    Picker("Input channel", selection: $transport.inputChannel) {
                        ForEach(transport.inputChannelChoices) { choice in
                            Text(choice.label).tag(choice.index)
                        }
                    }
                    .disabled(transport.inputChannelChoices.count <= 1)
                }
                Picker("Output", selection: $transport.outputDeviceID) {
                    Text("None").tag(AudioDeviceID?.none)
                    ForEach(transport.devices.filter(\.hasOutput)) { device in
                        Text("\(device.name) (\(device.outputChannels) out)")
                            .tag(AudioDeviceID?.some(device.id))
                    }
                }
                if transport.outputDevice != nil {
                    Picker("Output channels", selection: $transport.outputPair) {
                        ForEach(transport.outputPairChoices) { pair in
                            Text(pair.label).tag(pair.index)
                        }
                    }
                    .disabled(transport.outputPairChoices.count <= 1)
                }
                if transport.inputDeviceID != transport.outputDeviceID {
                    Label(
                        "Different input/output devices: a private aggregate device with drift compensation will be used. Prefer one interface for both when possible.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Button("Refresh devices") { transport.refreshDevices() }
            }

            Section("Format") {
                Picker("Sample rate", selection: $transport.sampleRate) {
                    ForEach(transport.availableSampleRates, id: \.self) { rate in
                        Text("\(Int(rate)) Hz").tag(rate)
                    }
                }
                Picker("Buffer size", selection: $transport.bufferFrames) {
                    ForEach(transport.availableBufferSizes, id: \.self) { size in
                        Text("\(size) samples (\(String(format: "%.1f", Double(size) / transport.sampleRate * 1000)) ms)")
                            .tag(size)
                    }
                }
            }

            Section("Reported latency (from driver)") {
                latencyGrid
            }

            Section("Loopback calibration") {
                Text("Connect the interface output to the guitar input with a cable (or use a virtual loopback device), then measure the true round-trip latency. This replaces the driver-reported estimate — drivers often lie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(transport.isCalibrating ? "Measuring…" : "Calibrate now") {
                        transport.runCalibration()
                    }
                    .disabled(transport.isCalibrating || transport.isRunning)
                    if let message = transport.calibrationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let calibration = transport.calibration {
                    LabeledContent("Stored measurement") {
                        Text(String(
                            format: "%.2f ms (%.1f samples, sd %.2f)",
                            calibration.roundtripMs, calibration.roundtripSamples, calibration.sdSamples
                        ))
                        .monospacedDigit()
                    }
                } else {
                    LabeledContent("Stored measurement") {
                        Text("none for this device/channel/rate/buffer combination")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Manual driver-error compensation") {
                HStack {
                    Slider(value: $transport.manualOffsetMs, in: -20...20, step: 0.1)
                    Text(String(format: "%+.1f ms", transport.manualOffsetMs))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
                Text("Extra correction added on top (like Ableton's Driver Error Compensation). Positive if your hits read consistently early, negative if late.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Effective compensation") {
                LabeledContent("Active constant") {
                    Text(String(
                        format: "%.2f ms (%@)",
                        transport.latencyModel.netCompensationMs(sampleRate: transport.sampleRate),
                        transport.latencyModel.usesCalibration ? "calibrated" : "reported"
                    ))
                    .monospacedDigit()
                    .foregroundStyle(transport.latencyModel.usesCalibration ? .green : .orange)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(transport.isRunning)
        .overlay {
            if transport.isRunning {
                Text("Stop the session to change audio settings")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var latencyGrid: some View {
        Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("Device").font(.caption).foregroundStyle(.secondary)
                Text("Safety").font(.caption).foregroundStyle(.secondary)
                Text("Stream").font(.caption).foregroundStyle(.secondary)
                Text("Buffer").font(.caption).foregroundStyle(.secondary)
                Text("Total").font(.caption).foregroundStyle(.secondary)
            }
            latencyRow("Input", transport.reportedInput)
            latencyRow("Output", transport.reportedOutput)
            GridRow {
                Text("Round-trip").font(.caption.weight(.semibold))
                Text("").gridCellColumns(4)
                Text(String(
                    format: "%d smp = %.2f ms",
                    transport.reportedInput.totalSamples + transport.reportedOutput.totalSamples,
                    Double(transport.reportedInput.totalSamples + transport.reportedOutput.totalSamples)
                        / transport.sampleRate * 1000
                ))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            }
        }
    }

    private func latencyRow(_ label: String, _ latency: ReportedLatency) -> GridRow<some View> {
        GridRow {
            Text(label).font(.caption)
            Text("\(latency.deviceLatency)").font(.caption).monospacedDigit()
            Text("\(latency.safetyOffset)").font(.caption).monospacedDigit()
            Text("\(latency.streamLatency)").font(.caption).monospacedDigit()
            Text("\(latency.bufferFrames)").font(.caption).monospacedDigit()
            Text("\(latency.totalSamples)").font(.caption).monospacedDigit()
        }
    }
}
