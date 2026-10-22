// Choosing a face for this phone's person, their assistant or the family room, as for a
// contact: `label` opens a choice of Photos or the camera, the photo is cut to a circle,
// and the face goes to the gateway, which keeps one small face for each and shows it to
// everyone in the family room, on both iPhones. Two choosers of one face on a page share
// one saving state, so neither starts a change while the other's is on its way. An
// assistant's face and the family room's also offer Edit Color, for the ring round it
// (RingColorSheet).
//
// A face that glows past its photo is given its glow's room inside the menu's own bounds,
// so pressing it and letting go draw the glow whole over the page, never cut at the face's
// edge; the page lays the face out at its own size all the same.

import PhotosUI
import SwiftUI
import UIKit

struct FaceChooser<Content: View>: View {
    /// Whose face it is to the gateway: a participant's id, or the family room's.
    let faceId: String
    let name: String
    /// What VoiceOver calls it: "Change Corey's photo" unless the page names it otherwise.
    let spokenLabel: String
    /// Shared by every chooser of the same face on one page. Nil keeps it to this one.
    let sharedSaving: Binding<Bool>?
    /// Whose ring Edit Color picks: an assistant's or the family room's. Nil offers none.
    let ringTarget: RingColorSheet.Target?
    /// How far the face's glow reaches past it, kept inside the menu's bounds.
    let glowReach: CGFloat
    let label: Content

    init(
        for participant: RoomParticipant,
        spokenLabel: String? = nil,
        sharedSaving: Binding<Bool>? = nil,
        glowReach: CGFloat = 0,
        @ViewBuilder label: () -> Content
    ) {
        self.init(
            faceId: participant.id,
            name: participant.name,
            spokenLabel: spokenLabel,
            sharedSaving: sharedSaving,
            ringTarget: participant.kind == .assistant ? .assistant(participant.id) : nil,
            glowReach: glowReach,
            label: label
        )
    }

    init(
        faceId: String,
        name: String,
        spokenLabel: String? = nil,
        sharedSaving: Binding<Bool>? = nil,
        ringTarget: RingColorSheet.Target? = nil,
        glowReach: CGFloat = 0,
        @ViewBuilder label: () -> Content
    ) {
        self.faceId = faceId
        self.name = name
        self.spokenLabel = spokenLabel ?? "Change \(name)'s photo"
        self.sharedSaving = sharedSaving
        self.ringTarget = ringTarget
        self.glowReach = glowReach
        self.label = label()
    }

    @Environment(AppModel.self) private var model
    @State private var item: PhotosPickerItem?
    @State private var isPickingPhoto = false
    @State private var isTakingPhoto = false
    /// The camera's shot, cut once the camera has gone.
    @State private var taken: UIImage?
    /// The photo being cut to a circle, once it has been read.
    @State private var photo: UIImage?
    @State private var isSavingAlone = false
    @State private var refusal: String?
    @State private var isEditingRing = false

    /// Whether a face is on its way to the gateway, from this chooser or one it shares with.
    private var isSaving: Binding<Bool> {
        sharedSaving ?? $isSavingAlone
    }

    /// What VoiceOver says the ring round the face is, where Edit Color picks one.
    private var ringName: String? {
        switch ringTarget {
        case .assistant(let assistant):
            return RingColorSheet.spokenName(of: model.settings.assistantRings[assistant], for: .assistant(assistant))
        case .family:
            return RingColorSheet.spokenName(of: model.room.familyLook?.ring, for: .family)
        case nil:
            return nil
        }
    }

    var body: some View {
        Menu {
            Button("Choose Photo", systemImage: "photo.on.rectangle") {
                isPickingPhoto = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") {
                    isTakingPhoto = true
                }
            }
            if ringTarget != nil {
                Button("Edit Color", systemImage: "paintpalette") {
                    isEditingRing = true
                }
            }
        } label: {
            label
                .overlay {
                    if isSaving.wrappedValue {
                        ProgressView()
                    }
                }
                .padding(glowReach)
                .contentShape(glowReach > 0 ? AnyShape(Circle()) : AnyShape(Rectangle()))
        }
        .padding(-glowReach)
        .disabled(isSaving.wrappedValue)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(ringName.map { "\($0) ring" } ?? "")
        .sheet(isPresented: $isEditingRing) {
            if let ringTarget {
                RingColorSheet(target: ringTarget, name: name, family: model.room.familyLook?.ring)
            }
        }
        .photosPicker(isPresented: $isPickingPhoto, selection: $item, matching: .images)
        .fullScreenCover(isPresented: $isTakingPhoto, onDismiss: {
            photo = taken
            taken = nil
        }) {
            CameraPicker(isPhotoOnly: true) { shot in
                if case .photo(let image)? = shot {
                    taken = image
                }
                isTakingPhoto = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: item) { _, picked in
            guard let picked else {
                return
            }
            item = nil
            Task {
                if let data = try? await picked.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photo = image
                }
            }
        }
        .sheet(isPresented: Binding(get: { photo != nil }, set: { isShown in
            if !isShown {
                photo = nil
            }
        })) {
            if let photo {
                FaceCropView(image: photo, name: name) { jpeg in
                    save(jpeg)
                }
            }
        }
        .alert("The photo was not saved", isPresented: Binding(get: { refusal != nil }, set: { isShown in
            if !isShown {
                refusal = nil
            }
        })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    private func save(_ jpeg: Data) {
        let saving = isSaving
        guard !saving.wrappedValue else {
            return
        }
        saving.wrappedValue = true
        Task {
            do {
                try await model.room.setFace(of: faceId, jpeg: jpeg, side: FaceCropView.side)
            } catch {
                refusal = ErrorText.describe(error)
            }
            saving.wrappedValue = false
        }
    }
}
