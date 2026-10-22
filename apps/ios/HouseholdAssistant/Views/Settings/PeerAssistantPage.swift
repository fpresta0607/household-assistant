// The other household's assistant, opened from the top of the family room: who she is,
// her voice with a sample, her model and how she takes part in the room, with nothing to
// change. Only her own person changes her, from their own iPhone. What shows here comes
// across the relay with the room (`peerAssistant`), and her sample is spoken by this
// phone's own gateway in her voice.

import SwiftUI

struct PeerAssistantPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let peer = model.room.peerAssistant
        let name = peer?.name ?? participant?.name ?? "The other assistant"
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ContactHeader(name: name, role: "\(model.otherPersonName)'s assistant") {
                        AssistantAvatar(emoji: participant?.emoji, photo: participant?.avatar, size: 96, ring: ring)
                            .shadow(color: ring.ringColor.opacity(0.35), radius: 14, y: 8)
                    }
                    if let peer {
                        SettingsGroup("Voice", refusal: model.assistantSettings.sampleRefusal) {
                            HStack(spacing: 0) {
                                VoiceSampleButton(voice: peer.voice, words: AssistantPage.sampleWords(name), voiceName: peer.voiceName)
                                    .padding(.leading, 16)
                                SettingsRow(peer.voiceName) {
                                    VoiceSampleBars(voice: peer.voice, words: AssistantPage.sampleWords(name))
                                }
                            }
                        }
                        SettingsGroup(note: "Only \(model.otherPersonName) changes \(name), from \(model.otherPersonName)'s own iPhone.") {
                            SettingsRow("Model") {
                                RowValue(text: peer.modelName, opensPage: false)
                            }
                            SettingsRow("In the family room") {
                                RowValue(text: peer.familyRoom, opensPage: false)
                            }
                        }
                    } else {
                        SettingsGroup(note: "\(name)'s voice and model arrive with the family room, from \(model.otherPersonName)'s side.") {
                            SettingsRow("Waiting for \(name)'s details") {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The other assistant in the room, for her face.
    private var participant: RoomParticipant? {
        model.room.participants.first { $0.kind == .assistant && $0.id != model.room.me?.assistant }
    }

    /// The ring picked on this phone for her face, nil while it is gold.
    private var ring: RingColor? {
        participant.flatMap { model.settings.assistantRings[$0.id] }
    }
}
